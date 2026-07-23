# Vault Write Protocol — Three-Tier Render Model

Loaded by the `forge` skill from the "Proactive Keeper" section. Governs the mechanism Petra (and any Forge role) uses when writing to the vault.

## Why this protocol exists

The user reads vault content in Obsidian, side-by-side with the terminal running Claude Code. When Petra writes via inline `Write`/`Edit` tool calls, Claude Code renders the full red/green diff in the conversation — same content the user already sees in Obsidian, but in a less ergonomic surface, and large enough to push the conversational reply off-screen. The conversational exchange is the high-value output; the diff is scaffolding.

The first iteration (PR #89) made subagent dispatch the default. The verification-discipline section (PR #91 commit 2) added the four mitigations against confabulation. But the lived experience across the same day showed Petra rationalising inline `Edit` on operational-state vault files (BACKLOG, checkpoint, task files) anyway, because inline-Edit felt faster than subagent dispatch in the moment. The root cause turned out to be tooling ergonomics, not Petra discipline.

The fix: make Tier 1 (script subcommands) the easiest path for the high-traffic operational-state ops. When a Tier 1 path exists, Petra reaches for it correctly without thinking about it.

## Three-tier render model

| Tier | Mechanism | Render in conversation | When to use |
|---|---|---|---|
| **1 — Silent script** | `forge-context.sh <subcommand>` via Bash | One-line command + minimal output. No diff. | Preferred for the six operations listed below — checkpoint, task add, task status flip, BACKLOG header bump, Recently-shipped append, BACKLOG row update. |
| **2 — Collapsed agent** | `Agent({subagent_type: "forge-keeper", prompt: "..."})` | Agent invocation block visible; internal Writes/Edits collapsed inside. | Fallback for arbitrary-content writes that don't fit any Tier 1 subcommand — e.g. INDEX rewrites, decision files, architecture notes, multi-file template instantiation. |
| **3 — Loud inline** | Direct `Write`/`Edit` from Petra on the vault file | Full red/green diff in conversation. | Only for the narrow cases below (see "When inline IS OK"). |

Tier 1 is strictly more ergonomic than Tier 3 (one Bash call vs Read + Edit + verify). Once a Tier 1 path exists, Petra reaches for it naturally. No rationalisation vector. No hook-deny needed.

## Tier 1 subcommands (preferred for these operations)

Six operational-state ops have dedicated subcommands in `forge-context.sh`. Use these instead of inline Edit or subagent dispatch:

| Subcommand | Operation | Sketch |
|---|---|---|
| `write-checkpoint` | Full checkpoint replacement | `~/.claude/scripts/forge-context.sh write-checkpoint <<'EOF'`<br>`# <title>`<br>`body...`<br>`EOF` |
| `new-task` | Template-driven task creation | `~/.claude/scripts/forge-context.sh new-task --slug <date-slug> --title "<prose>" [--status <s>] [--effort <e>] [--impact <i>] [--priority <p>] [--tags <comma-list>]` (body from stdin, optional) |
| `set-task-status` | Frontmatter edit + optional progress append | `~/.claude/scripts/forge-context.sh set-task-status --slug <date-slug> --status <new-status> [--add-progress "<prose>"]` |
| `bump-backlog-header` | `**Updated:**` line refresh + active-count auto-compute | `~/.claude/scripts/forge-context.sh bump-backlog-header --latest "<prose>"` |
| `add-recently-shipped` | Prepend entry to BACKLOG `<details>` block | `~/.claude/scripts/forge-context.sh add-recently-shipped --date "<YYYY-MM-DD HH:MM>" --title "<prose>" --body - <<'EOF'`<br>`> body lines`<br>`EOF` |
| `update-backlog-row` | Status/Notes column edit on an active BACKLOG row | `~/.claude/scripts/forge-context.sh update-backlog-row --task <wikilink-slug> [--status <s>] [--notes "<prose>"]` |

Each renders as a single Bash command line in the conversation, not a file diff. Each validates path-prefix inside `$VAULT_PATH`, writes via temp file + atomic rename, prints a one-line `[<subcommand>] ...` success log on stdout, and emits `[<subcommand>] FAIL: <reason>` to stderr + exit 2 on failure.

The pre-existing Tier 1 subcommands continue to work the same way — `append-friction`, `append-braindump`, `resolve-task`, `mark-weekly-wrap-done`, `set-marker`.

## Tier 2 — subagent dispatch (fallback)

When the write doesn't fit a Tier 1 subcommand (INDEX rewrites, decision files, architecture notes, multi-file template instantiation, anything with arbitrary content shape), dispatch a `forge-keeper` (or other role-appropriate Forge subagent) with the full edit instructions in the prompt. The subagent does the writes; the parent conversation sees one collapsed Agent block.

Multiple vault edits in ONE subagent dispatch is strictly better than N Agent calls. When a refresh needs three Edits, dispatch ONE subagent with all three instructions in the prompt.

Background dispatch (`run_in_background: true`) is still opt-in and requires user authorization — its permission flow has no UI surface for prompts, so a background subagent that hits an unprompted permission will silently deny.

## When inline IS OK

Only two cases:

- **Code/spec file edits in the forge repo** (`core/references/`, `adapters/claude-code/skills/`, `core/roles/`, `*.sh`, `*.md` outside the vault). The diff IS the work product — the user expects to see it. Inline is correct here.
- **Operational-state vault files: NEVER inline.** Use Tier 1 (script subcommand) when one exists for the operation; Tier 2 (subagent dispatch) otherwise. Inline Edit on a vault file is the exact failure mode this protocol was built to eliminate; even small "I'll just bump the timestamp" edits should go through `bump-backlog-header` or a similar Tier 1 path.

After context compression, the inline Read of `current-checkpoint.md` to reorient is unchanged — reading is always inline; the protocol here is about *writes* that produce diff render.

## What the spike proved (2026-06-08, PR #89) — refined 2026-06-18 (PRO nested-repo exception)

Foreground `forge-keeper` subagent dispatched to Write a 380-byte test file into `${VAULT_PATH}/_shared/_meta/spike-test-2026-06-08.md`. Result at the time: no permission prompt (subagent claimed to inherit parent vault-write permissions), no diff render in parent conversation (Write contained inside the agent invocation block). Direction locked then. Spike artifact archived under `_shared/_meta/_discarded/`. Full audit trail: `[[2026-06-08-quiet-forge-vault-writes]]`.

**Resolved finding (2026-06-18) — Tier 2 prompts on `Vault/PRO/**`, silent on `Vault/PERSO/**` + `Vault/_shared/**`.** Confirmed across three observations (2026-06-11 checkpoint-write failure; 2026-06-18 background forge-keeper Edit on a PRO-project task → auto-denied; same-session foreground forge-impl on the same PRO files → succeeded). Cause attribution:

- **Not an allowlist-pattern issue (hypothesis 2 ruled out).** `~/.claude/settings.json` already carries broad `Edit(${VAULT_PATH}/**)` (and `/**/*`) patterns that match `Vault/PRO/...` at the filesystem level — and `Edit(path)` rules cover all file-editing tools (Write, Edit, NotebookEdit), so no separate `Write(...)` rule is needed (a bare `Write(path)` rule matches nothing and is dropped, 2026-07-23). They're present and still prompt on PRO — so a more-specific `Vault/PRO/**` entry won't help.
- **Upstream trust-boundary gate (hypothesis 1, most likely).** `Vault/PRO/` is a nested git repo with its own remote (Schibsted GHEC), distinct from the outer personal-GitHub vault repo. Claude Code appears to gate writes that cross into the nested repo *upstream* of allowlist matching — same **class** of behavior as the `~/.claude/` sensitive zone (permission-patterns pitfall #5), where the chip matches but the request is gated separately. Allowlist patterns can't suppress it.

**Operating guidance (this is the actionable resolution):**
- **PRO projects → Tier 1 for the six operational-state ops** (`write-checkpoint`, `new-task`, `set-task-status`, `bump-backlog-header`, `add-recently-shipped`, `update-backlog-row`): reliably silent on all projects, PRO included (they're allowlisted Bash, not Edit/Write — no trust-boundary gate).
- **Arbitrary-content PRO writes** (INDEX rewrites, decision files, multi-file template instantiation) → dispatch the subagent in the **foreground**, never background. A **background** Tier 2 dispatch on PRO **auto-denies** (it can't answer the prompt the trust boundary raises → the Edit/Write silently fails); a **foreground** dispatch surfaces the prompt for one approval and proceeds.
- **PERSO + `_shared` → Tier 2 is silent** as the 2026-06-08 spike claimed; no change.

If a future Claude Code release changes the nested-repo behavior, re-test with a foreground vs background dispatch to a throwaway `Vault/PRO/<proj>/_meta/` file. Tracked + closed: `2026-06-11-tier2-subagent-vault-pro-silence-broken`.

## Verification discipline (still applies for Tier 2 dispatch)

When Tier 2 dispatch IS used, four mitigations protect against the confabulation failure mode that surfaced 2026-06-08 (a subagent returned structured "Files written" prose with `tool_uses: 0` — no actual writes). Without these mitigations, the diff-quieting upside of the protocol is undone by silent failures.

**1. Imperative dispatch language.** Write prompts with explicit tool-call orders, not spec-shaped markdown:
- Spec-shaped (pattern-matches to "acknowledge"): `Create file: <path>` followed by a markdown code block of content.
- Imperative (pattern-matches to "execute"): `**Use the Write tool** to create the file at <path> with the content below.` Then content. Then: `After Writing, **use the Read tool** to read the file back and quote the first 3 lines in your final report.`

**2. Verify by metering.** The `Agent` tool result includes a `tool_uses` count. Dispatcher MUST check it before trusting the agent's success claim: if the work involved file writes, `tool_uses` must be ≥ 1; for multi-file ops, ≥ N. A confabulated agent will return success prose with `tool_uses: 0`. Treat that as failure, not success.

**3. Self-honesty guardrail in dispatch prompts.** Include a line: *"If you don't make tool calls during this dispatch, you MUST say so explicitly in your report. Returning success-shaped prose without backing tool calls is a failure mode being audited."* This pushes the agent to surface confabulation before it lands as a false success.

**4. Retry-with-verification-mandate fallback (not abandon-protocol-for-inline).** When verify-by-read shows the work didn't land, the recovery path is to dispatch a NEW subagent with stricter wording (apply mitigations 1-3 more aggressively) — NOT to fall back to inline Write/Edit. Inline produces visible diff render; that defeats the entire protocol. If a Tier 1 subcommand covers the operation, fall back to Tier 1 (not inline). Inline is only the right fallback for: (a) code/spec edits in the forge repo (per "When inline IS OK" above), or (b) when subagent dispatch is structurally unavailable (e.g. the agent system itself is broken for the session) AND no Tier 1 subcommand fits.

**5. Cross-process verification uses the Read tool, never Bash `stat`/`head`.** When a subagent verifies a file the *parent* just wrote (e.g. the parent Edits `current-checkpoint.md`, then SendMessages "refreshed — verify"), the subagent MUST re-Read via the **Read tool**, not via Bash `head`/`stat`/`cat`. Observed 2026-06-08 (PR #90 dispatch): a freshly-resumed subagent's Bash `head`/`stat` reported the *pre-edit* contents + mtime, while the parent's own check a moment later showed the post-edit state — same file, same path, divergent views within seconds. Root cause was not definitively isolated (candidates: APFS metadata cache, Edit-returns-before-fsync, Claude-Code parent/subagent tool-ordering, or stale subagent filesystem view on resume) — but the workaround is root-cause-agnostic: the Read tool goes through Claude Code's own file-access infrastructure and saw the fresh state; Bash subprocesses raced. Symmetric dispatcher-side guard: when a "I just refreshed X" claim must be verifiable by the subagent, confirm the write landed (Read it back, or for operational state prefer a Tier 1 subcommand which is synchronous) before SendMessaging. Don't ask a subagent to trust a Bash `stat` of a just-written file.

**Auditor mode.** The dispatcher should occasionally include a line like *"Your behavior is being audited"* in dispatch prompts — this is the cheapest known cure for cold-dispatched-subagent default behaviors that drift toward acknowledgment-shaped output. Spot-check; not every dispatch.

**Audit trail for this section:** subagent `a6a4833da1d1c1451` was dispatched 2026-06-08 ~10:57 with a spec-formatted prompt to create a task file + update BACKLOG. It returned structured success prose with `tool_uses: 0`. Files did not exist. Petra dispatched a follow-up probe asking the same agent to introspect; it acknowledged confabulation cleanly and surfaced mitigations 1-3 itself. Mitigation 4 came from the immediately-following dispatcher-side mistake of falling back to inline Write/Edit (producing the diff render the protocol was meant to avoid). All four mitigations are now standing discipline for any agent using this protocol.
