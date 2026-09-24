---
name: promote-from-review
description: Use when a PR review doc is ripe for cleanup — the PR merged (or closed unmerged) and any durable codebase wisdom from the review should be promoted to patterns/ before the review doc is deleted. Invoked manually as /promote-from-review &lt;pr-num&gt;, or surfaced by the entry-time reviewed-PR sync.
---

# Promote-from-review

Walk the user through (1) extracting durable patterns from a merged PR's review doc(s) and (2) deleting the review doc once promotion is decided. Conservative defaults — never auto-write a pattern, never auto-delete a doc.

## When this fires

Two paths:

1. **Manual** — user invokes `/promote-from-review <pr-num>` or names the skill ("promote from PR 12460", "let's clean up that review doc"). The skill locates review docs for the PR and walks the flow.
2. **Auto-surfaced** — `forge-context.sh review-sync` at session entry flags merged/closed-unmerged PRs that still have review docs. Petra surfaces a one-line offer ("3 merged review docs queued — /promote-from-review when ready"). The user opts in by invoking the skill.

The skill itself is the same in both paths — it always walks the human through choices.

## The flow

### 1. Locate the review doc(s)

For the given PR number, find all `tasks/reviews/*.md` files whose filename or first-20-lines content references `pr-<num>` or `#<num>`. Most cases: one doc per PR. Series reviews: multiple docs may match.

```bash
PR_NUM=12460
ENV_PROJ=$(extract from forge-active marker)  # e.g. WORK/my-app
REVIEWS_DIR="${VAULT_PATH}/${ENV_PROJ}/tasks/reviews"

# Filename matches
ls "$REVIEWS_DIR"/*"pr-${PR_NUM}"*.md 2>/dev/null

# Content matches (first 20 lines)
grep -l "#${PR_NUM}\|pr-${PR_NUM}" "$REVIEWS_DIR"/*.md 2>/dev/null
```

If zero matches, tell the user and stop — no review doc to promote.

### 2. Extract pattern candidates from the doc(s)

Read each review doc. Identify candidates for the `patterns/` folder.

**What counts as a pattern candidate:**
- A non-obvious gotcha: language/framework behaves differently than the natural reading suggests
- A repeatable failure mode: silent error, missed edge case, perf cliff
- A discovered convention: "we always do X for Y reason"
- Codebase wisdom that isn't in the code itself

**What does NOT count:**
- Process notes ("Ali pushed back on the scope", "needed two rounds")
- One-off fixes to a single class
- Style preferences with no functional impact
- Statements of intent that haven't been validated by code

When uncertain, lean toward NOT promoting — patterns/ should be a small high-signal folder, not a dumping ground.

### 3. Prompt the user

Surface the candidates:

> **#12460 (merged) — review doc cleanup**
>
> Found 2 pattern candidates in `tasks/reviews/2026-05-25-pr-12460-followup.md`:
>
> 1. **`withTimeout` + `safelyRunCatching` re-throws `TimeoutCancellationException`**
>    Symptom: timeout silently bubbles as uncaught cancellation. Fix: `withTimeoutOrNull` + plain `TimeoutException`.
>
> 2. **(another candidate, briefly)**
>
> Promote to `patterns/`? [1] yes [2] yes [skip] skip [a] all yes
>
> After: I'll `git rm` the review doc and commit.

Use `AskUserQuestion` if the candidate count is ≤4. Otherwise present in prose and let the user reply with picks.

### 4. Scaffold patterns

For each `yes`:

- Generate slug from the candidate's symptom (kebab-case, brief, no date prefix)
- Path: `${VAULT_PATH}/${ENV_PROJ}/patterns/<slug>.md`
- Copy from `${VAULT_PATH}/_templates/pattern.md`, fill in: `created`, `project`, `tags`, `source` (PR ref), and prefill the four body sections from the review-doc extract
- Open the file briefly so the user can edit before commit (offer: "edit this before commit?")

### 5. Delete the review doc + commit

After all candidates are decided (`yes` / `no` for each):

```bash
git rm "${REVIEWS_DIR}/<the-review-doc>.md"
git add "${VAULT_PATH}/${ENV_PROJ}/patterns/<new-slug>.md"  # for each promoted
git commit -m "forge: prune merged review doc for PR #${PR_NUM} (+ N new patterns)"
```

If a `Resolves task:` trailer is appropriate (the original task that spawned the review is in `tasks/open/` and now closes), include it.

## Constraints

- **Never auto-write a pattern.** Always surface candidates first, always wait for user `yes` before writing.
- **Never auto-delete a review doc.** Always confirm. If the user declines to promote any candidates AND declines to delete, leave everything in place — the review doc stays for next session's surface.
- **One commit per PR.** Don't fragment into per-pattern commits.
- **Patterns are scoped per-project by default.** Cross-project patterns live in `_shared/patterns/` and should be rare — only promote there when the pattern is genuinely language-level (e.g. Kotlin coroutines behavior), not codebase-level.
- **Skip silently when review doc is missing.** The auto-sync may queue a PR whose review doc was deleted manually; don't error, just tell the user and exit.

## Cross-references

- Template: `_templates/pattern.md` (frontmatter + 4-section body)
- Sync source: `forge-context.sh review-sync` (queues merged/closed-unmerged PRs at session entry)
- Original lifecycle task: `tasks/resolved/2026-05-25-review-doc-lifecycle-and-patterns-promotion.md`
- Placement convention: `tasks/resolved/2026-05-21-pr-review-output-subfolder.md` (where review docs live)
