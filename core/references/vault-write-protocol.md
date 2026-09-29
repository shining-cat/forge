# Vault Write Protocol — Three-Tier Render Model

Loaded by the `forge` skill from the "Proactive Keeper" section. Governs authored vault content in every adapter.

**Keeper is the writer.** Petra and other roles may read, reason about, and prepare vault changes, but dispatch a synchronous Keeper to execute every authored vault mutation, including Tier 1 script commands. Keeper verifies the result. If dispatch or verification fails, report the write as blocked; do not fall back to a main-session edit or another role. Session markers, wellness runtime state, calendar caches, and other machine-managed state are lifecycle-script responsibilities, not authored content. This ownership rule does not constrain edits to the Forge source repository or installation directory.

This is a workflow boundary, not an OS security boundary. A same-user shell can invoke the scripts regardless of role. Claude Code may additionally deny direct main-session edits when its hook supplies subagent identity; Copilot CLI's documented `PreToolUse` input does not identify the tool's subagent, so it cannot enforce that distinction. Do not infer identity from a shared session ID or from an active-subagent count.

## Why this protocol exists

The user reads vault content in Obsidian, side-by-side with the terminal running Claude Code. When Petra writes via inline `Write`/`Edit` tool calls, Claude Code renders the full red/green diff in the conversation — same content the user already sees in Obsidian, but in a less ergonomic surface, and large enough to push the conversational reply off-screen. The conversational exchange is the high-value output; the diff is scaffolding.

The first iteration (PR #89) made subagent dispatch the default. The verification-discipline section (PR #91 commit 2) added the four mitigations against confabulation. But the lived experience across the same day showed Petra rationalising inline `Edit` on operational-state vault files (BACKLOG, checkpoint, task files) anyway, because inline-Edit felt faster than subagent dispatch in the moment. The root cause turned out to be tooling ergonomics, not Petra discipline.

The fix: make Tier 1 (script subcommands) the easiest path for the high-traffic operational-state ops. Petra dispatches Keeper for the write; Keeper chooses Tier 1 where it fits.

## Three-tier render model

| Tier | Mechanism | Render in conversation | When to use |
|---|---|---|---|
| **1 — Silent script** | Keeper invokes `forge-context.sh <subcommand>` via Bash | One-line command + minimal output. No diff. | Preferred for typed authored operations — checkpoint, task, BACKLOG, friction, and braindump updates. |
| **2 — Collapsed edit** | Keeper uses its `Write`/`Edit` tool | Agent invocation block visible; internal edits collapsed. | Arbitrary authored content that has no Tier 1 subcommand — e.g. INDEX rewrites, decision files, architecture notes. |
| **3 — Blocked** | Keeper unavailable or write unverified | No write claimed. | Report or defer; Petra never takes over an authored vault write. |

Petra dispatches Keeper with the exact context and desired outcome. Keeper picks the lowest applicable tier. The runtime-specific hook is only a backstop where the tool payload supports it, not the source of this rule.

## Tier 1 subcommands (preferred for these operations)

Operational-state ops have dedicated subcommands in `forge-context.sh`. Keeper uses these instead of raw Edit:

| Subcommand | Operation | Sketch |
|---|---|---|
| `write-checkpoint` | Full checkpoint replacement | `~/.claude/scripts/forge-context.sh write-checkpoint <<'EOF'`<br>`# <title>`<br>`body...`<br>`EOF` |
| `new-task` | Template-driven task creation | `~/.claude/scripts/forge-context.sh new-task --slug <date-slug> --title "<prose>" [--status <s>] [--effort <e>] [--impact <i>] [--priority <p>] [--tags <comma-list>]` (body from stdin, optional) |
| `set-task-status` | Frontmatter edit + optional progress append | `~/.claude/scripts/forge-context.sh set-task-status --slug <date-slug> --status <new-status> [--add-progress "<prose>"]` |
| `bump-backlog-header` | `**Updated:**` line refresh + active-count auto-compute | `~/.claude/scripts/forge-context.sh bump-backlog-header --latest "<prose>"` |
| `add-recently-shipped` | Prepend entry to BACKLOG `<details>` block | `~/.claude/scripts/forge-context.sh add-recently-shipped --date "<YYYY-MM-DD HH:MM>" --title "<prose>" --body - <<'EOF'`<br>`> body lines`<br>`EOF` |
| `update-backlog-row` | Status/Notes/Effort/Impact column edit on an EXISTING active BACKLOG row | `~/.claude/scripts/forge-context.sh update-backlog-row --task <wikilink-slug> [--status <s>] [--notes "<prose>"] [--effort <e>] [--impact <i>]` |
| `add-backlog-row` | Insert a NEW row under an existing BACKLOG section (dup-guarded) | `~/.claude/scripts/forge-context.sh add-backlog-row --task <slug> --section "<header-substring>" --effort <e> --impact <i> --status <s> [--notes "<prose>"] [--label "<link text>"]` |
| `remove-backlog-row` | Delete an existing active BACKLOG row (history in `<details>` is never touched) | `~/.claude/scripts/forge-context.sh remove-backlog-row --task <wikilink-slug>` |

Each renders as a single Bash command line in the conversation, not a file diff. Each validates path-prefix inside `$VAULT_PATH`, writes via temp file + atomic rename, prints a one-line `[<subcommand>] ...` success log on stdout, and emits `[<subcommand>] FAIL: <reason>` to stderr + exit 2 on failure.

The pre-existing authored Tier 1 subcommands continue to work the same way — `append-friction`, `append-braindump`, `resolve-task`. Runtime-state commands such as `mark-weekly-wrap-done` and `set-marker` are exempt from Keeper ownership.

## Tier 2 — arbitrary writes by Keeper

When the write doesn't fit a Tier 1 subcommand (INDEX rewrites, decision files, architecture notes, multi-file template instantiation), dispatch `forge-keeper` with the full edit instructions. Keeper does the writes; the parent conversation sees one collapsed Agent block.

Multiple vault edits in ONE subagent dispatch is strictly better than N Agent calls. When a refresh needs three Edits, dispatch ONE subagent with all three instructions in the prompt.

### Synchronous is the default for single-agent dispatch

**A single Keeper dispatch (Tier 1 or Tier 2) MUST run synchronously — `run_in_background: false`.** This is not a performance preference; it's the fix for a hard blocker.

Background dispatch (`run_in_background: true`) spawns the subagent in a **separate tmux/iTerm pane**. A fresh pane hits Claude Code's folder-trust gate — *"Do you trust the files in this folder?"* — which has no UI surface a background agent can answer, so the spawn stalls or the prompt is idle-dropped and the subagent dies before doing any work. This bites **all projects**, not just PRO — it is a distinct blocker from the PRO nested-repo permission prompt documented below. Observed 2026-08-04: five background keepers all stalled on the trust gate; corroborated 2026-08-07 (a synchronous keeper ran clean — in-process, no pane, no gate).

A synchronous dispatch runs **in-process** in the main session — no pane, no trust gate, and it inherits the session's already-granted trust. So it's both simpler and strictly more reliable for the single-agent case, where there's no parallelism to lose anyway.

Background/pane dispatch earns its keep only for **genuine parallel fan-out** — agent-team reviews, the weekly friction harvest — where N subagents truly run at once. That path *does* hit the trust gate per pane; making it gate-free needs the folder pre-trusted at install and is tracked separately (`2026-08-07-pretrust-parallel-fanout-folder-gate`). Until then, parallel fan-out requires accepting the trust gate interactively, so it's a foreground-user operation, not a fire-and-forget background one.

Background dispatch also remains subject to the pre-existing permission caveat: even setting the trust gate aside, its permission flow has no UI surface for prompts, so a background subagent that hits an unprompted permission will silently deny.

## When Petra may edit directly

Only two cases:

- **Code/spec file edits in the forge repo** (`core/references/`, `adapters/claude-code/skills/`, `core/roles/`, `*.sh`, `*.md` outside the vault). The diff IS the work product — the user expects to see it. Inline is correct here.
- **Authored vault files: NEVER inline, including via Bash.** Dispatch Keeper for the Tier 1 script or the arbitrary edit. Machine-managed runtime state remains with its lifecycle scripts; those calls need not dispatch Keeper.

After context compression, the inline Read of `current-checkpoint.md` to reorient is unchanged — reading is always inline; the protocol here is about *writes* that produce diff render.

## What the spike proved (2026-06-08, PR #89) — refined 2026-06-18 (PRO nested-repo exception)

Foreground `forge-keeper` subagent dispatched to Write a 380-byte test file into `${VAULT_PATH}/_shared/_meta/spike-test-2026-06-08.md`. Result at the time: no permission prompt (subagent claimed to inherit parent vault-write permissions), no diff render in parent conversation (Write contained inside the agent invocation block). Direction locked then. Spike artifact archived under `_shared/_meta/_discarded/`. Full audit trail: `[[2026-06-08-quiet-forge-vault-writes]]`.

**Resolved finding (2026-06-18) — Tier 2 prompts on `Vault/PRO/**`, silent on `Vault/PERSO/**` + `Vault/_shared/**`.** Confirmed across three observations (2026-06-11 checkpoint-write failure; 2026-06-18 background forge-keeper Edit on a PRO-project task → auto-denied; same-session foreground forge-impl on the same PRO files → succeeded). Cause attribution:

- **Not an allowlist-pattern issue (hypothesis 2 ruled out).** `~/.claude/settings.json` already carries broad `Edit(${VAULT_PATH}/**)` (and `/**/*`) patterns that match `Vault/PRO/...` at the filesystem level — and `Edit(path)` rules cover all file-editing tools (Write, Edit, NotebookEdit), so no separate `Write(...)` rule is needed (a bare `Write(path)` rule matches nothing and is dropped, 2026-07-23). They're present and still prompt on PRO — so a more-specific `Vault/PRO/**` entry won't help.
- **Upstream trust-boundary gate (hypothesis 1, most likely).** `Vault/PRO/` is a nested git repo with its own remote (Schibsted GHEC), distinct from the outer personal-GitHub vault repo. Claude Code appears to gate writes that cross into the nested repo *upstream* of allowlist matching — same **class** of behavior as the `~/.claude/` sensitive zone (permission-patterns pitfall #5), where the chip matches but the request is gated separately. Allowlist patterns can't suppress it.

**Operating guidance (this is the actionable resolution):**
- **PRO projects → Keeper invokes Tier 1 for the eight operational-state ops** (`write-checkpoint`, `new-task`, `set-task-status`, `bump-backlog-header`, `add-recently-shipped`, `update-backlog-row`, `add-backlog-row`, `remove-backlog-row`): reliably silent on all projects, PRO included (they're allowlisted Bash, not Edit/Write — no trust-boundary gate).
- **Arbitrary-content PRO writes** (INDEX rewrites, decision files, multi-file template instantiation) → dispatch the subagent in the **foreground**, never background. A **background** Tier 2 dispatch on PRO **auto-denies** (it can't answer the prompt the trust boundary raises → the Edit/Write silently fails); a **foreground** dispatch surfaces the prompt for one approval and proceeds.
- **PERSO + `_shared` → Tier 2 is silent** as the 2026-06-08 spike claimed; no change.

If a future Claude Code release changes the nested-repo behavior, re-test with a foreground vs background dispatch to a throwaway `Vault/PRO/<proj>/_meta/` file. Tracked + closed: `2026-06-11-tier2-subagent-vault-pro-silence-broken`.

## Verification discipline (still applies for Tier 2 dispatch)

When Tier 2 dispatch IS used, four mitigations protect against the confabulation failure mode that surfaced 2026-06-08 (a subagent returned structured "Files written" prose with `tool_uses: 0` — no actual writes). Without these mitigations, the diff-quieting upside of the protocol is undone by silent failures.

**1. Imperative dispatch language.** Write prompts with explicit tool-call orders, not spec-shaped markdown:
- Spec-shaped (pattern-matches to "acknowledge"): `Create file: <path>` followed by a markdown code block of content.
- Imperative (pattern-matches to "execute"): `**Use the Write tool** to create the file at <path> with the content below.` Then content. Then: `After Writing, **use the Read tool** to read the file back and quote the first 3 lines in your final report.`

**2. Verify by metering.** Where the dispatch result exposes a `tool_uses` count, check it before trusting the success claim: if the work involved file writes, `tool_uses` must be ≥ 1 (but a typed helper may write multiple files in one call). A confabulated agent will return success prose with `tool_uses: 0`. Treat that as failure, not success.

**3. Self-honesty guardrail in dispatch prompts.** Include a line: *"If you don't make tool calls during this dispatch, you MUST say so explicitly in your report. Returning success-shaped prose without backing tool calls is a failure mode being audited."* This pushes the agent to surface confabulation before it lands as a false success.

**4. Retry-with-verification-mandate fallback (not abandon-protocol-for-inline).** When verify-by-read shows the work didn't land, retry with Keeper and stricter wording (apply mitigations 1-3 more aggressively) — NOT with Petra or another role. If a typed helper fits, Keeper may switch to Tier 1. If Keeper remains unavailable, report/defer the authored write; only code/spec edits outside the vault may proceed inline.

**5. Cross-process verification uses the Read tool, never Bash `stat`/`head`.** A historical parent-write experiment (2026-06-08, PR #90) found that a freshly-resumed subagent's Bash `head`/`stat` reported pre-edit content while the parent's check showed the post-edit state; the Read tool saw the fresh state. Parent writes to authored vault content are no longer allowed, but this verification lesson still applies: Keeper reads back its writes, and the dispatcher checks the result before claiming success.

**Auditor mode.** The dispatcher should occasionally include a line like *"Your behavior is being audited"* in dispatch prompts — this is the cheapest known cure for cold-dispatched-subagent default behaviors that drift toward acknowledgment-shaped output. Spot-check; not every dispatch.

**Audit trail for this section:** subagent `a6a4833da1d1c1451` was dispatched 2026-06-08 ~10:57 with a spec-formatted prompt to create a task file + update BACKLOG. It returned structured success prose with `tool_uses: 0`. Files did not exist. Petra dispatched a follow-up probe asking the same agent to introspect; it acknowledged confabulation cleanly and surfaced mitigations 1-3 itself. Mitigation 4 came from the immediately-following dispatcher-side mistake of falling back to inline Write/Edit (producing the diff render the protocol was meant to avoid). All four mitigations are now standing discipline for any agent using this protocol.
