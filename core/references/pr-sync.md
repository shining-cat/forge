# PR Sync — data gathering + why explicit

Background for the `### 3. Reconcile GitHub PRs` stub in `forge/SKILL.md`. The short version is one line — *"compose `gh pr list` with explicit `--repo` and `GH_HOST` values; never let gh guess from cwd"*. Load this file when implementing or debugging PR sync.

## Data gathering steps

1. Parse `current-checkpoint.md` for PR numbers (`#(\d+)`) — these are the "known" PRs.
2. **Resolve the remote explicitly.** Run `git -C {project_path} remote get-url origin` and parse it into `{host}` and `{owner/repo}`:
   - SSH (`git@github.com:owner/repo.git`) → host = part after `git@` before `:`, repo = part after `:` minus `.git`
   - HTTPS (`https://github.com/owner/repo.git`) → host = part after `://` before `/`, repo = the path minus `.git`
3. **Compose the `gh` call with explicit values** — never let `gh` guess from cwd or git config alone (it silently defaults to `github.com` and may pick the wrong repo on multi-project sessions or enterprise hosts):
   - GitHub.com: `gh pr list --author @me --repo {owner/repo} --state all --limit 20 --json number,title,state,reviewDecision,mergedAt,createdAt`
   - Enterprise (e.g. `github.acme.com`): prepend `GH_HOST={host}` to the same command.
4. Filter results: keep PRs that are either **(a)** known in vault, or **(b)** open AND created less than 5 days ago.

## Why explicit (and why this matters)

Without the resolve + pass-through, the call can return empty silently — `gh` defaults to `github.com` and guesses the repo from cwd, which fails on non-github.com hosts and on workspaces with sibling repos of similar names.

**Documented failure**: enterprise repo `finn/frontpage-layout-v2` on `github.schibsted.io` came back empty because `gh` defaulted to github.com and guessed `schibsted-nmp/frontpage-layout-v2`.

The same hazard hits **any subagent** dispatched to do PR sync — subagents inherit cwd but not context about which remote matters, so explicit values are mandatory in dispatch prompts too.

## Update rules

- **Known PR now merged/closed** → move to "Completed" in checkpoint, note merge date.
- **Known PR review status changed** → update its entry in "In review".
- **New open PR (< 5 days, not in vault)** → add to "In review".
- **Unknown merged/closed PR** → ignore (no noise for work handled outside Forge).

## Entry output

Show a compact summary (only when there's something to report):

```
--- PR Sync ---
#12179 PF-1656: MERGED (was: in review)
#12192 PF-1729: approved
+ #12183 PF-1668: review required (new)
---
```

`+` prefix for PRs not previously in the vault.

After showing the summary, update `current-checkpoint.md` with the reconciled state.

## Reviewed-PR sync (`forge-context.sh review-sync`)

Alongside the author=me sync above, run `~/.claude/scripts/forge-context.sh review-sync` to walk `${VAULT_PATH}/{ENV}/{PROJECT}/tasks/reviews/*.md` and emit a row for any review doc whose PR is merged or closed-unmerged. Output format mirrors the own-PR rows but uses a `~` prefix:

```
~ #12460 COMM-3670: Extract UseCases from ConvVM: MERGED — review doc cleanup queued
```

Merge these rows into the same `--- PR Sync ---` block in the entry summary. After the summary, queue a single line offer to the user (don't run the cleanup automatically):

> *"N merged review docs queued — `/promote-from-review <pr>` when ready."*

The user opts in when they have headspace. `/promote-from-review` walks them through extracting durable patterns from the review doc into `patterns/<slug>.md`, then `git rm`s the review doc.

`--backfill` mode (`review-sync --backfill`) scans all projects under VAULT_PATH, not just the active one. Useful for first-deploy cleanup of accumulated review docs across multiple projects.

Cost: one `gh pr view` per review doc, typically ≤5 per project. `gh` caches; acceptable for entry-time invocation. Silent on `gh` missing or `gh pr view` failures (review-sync degrades to "no rows" rather than blocking entry).
