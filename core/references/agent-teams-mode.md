# Agent-Teams Mode — Full Protocol

Loaded by the `forge` skill **only** when Petra is considering or actively spawning an agent team. Most Forge work does not need this file — sequential subagent dispatch is the default.

## When to spawn a team (Petra's call)

- **Pattern A — Pair / triplet of different roles** on the same artifact. PR review needing both structural validation (Reviewer) and friction analysis (Refiner). Design discussion needing both forward design (Architect) and adversarial failure analysis (Debugger).
- **Pattern B — Multiple instances of the same role**, each seeded with a different hypothesis. Hard debugging where root cause is unclear (3-5 Debuggers, adversarial debate). Security investigation with multiple attack vectors. The value is anti-anchoring through competing hypotheses, not "more thorough coverage."
- **Pattern C — Same role, scope-partitioned**. PR review split into separate concerns (security / performance / test coverage), each owned by a different Reviewer.

**Trigger convention:** Petra detects the workflow shape and asks before spawning ("This looks like a multi-perspective review — should I spin up a team?"). The user can also explicitly request a team.

**Substrate requirement:** `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `~/.claude/settings.json` (env var). Takes effect on session restart. Requires Claude Code v2.1.32+. If session entry reported "Team substrate: missing", see the substrate-missing fallback below — Pattern A still runs inline.

## Pattern A — when to spawn (trigger heuristic)

Petra evaluates each candidate PR (or design doc / plan) against the trigger list below. Each trigger that fires adds its weight to a running score. **Score ≥ 3** → Petra surfaces the call: "Score X from triggers [list] — Pattern A territory?" The user confirms or overrides. **Score 0-2** → Reviewer-solo, no friction.

| # | Trigger | Weight |
|---|---|---|
| 1 | **PR description doesn't fully account for the change surface** (mismatch between stated intent and diff scope) | 3 |
| 2 | **PR appears to bundle multiple concerns / no decomposition into smaller batches** (single commit doing several distinct things, multiple unrelated module touches, no commit hierarchy) — not raw LOC, since pure deletion can be huge and trivial | 2 |
| 3 | **Touches shared components** (utility classes, design system, base components) | 2 |
| 4 | **Modifies control flow over multiple paths** (`when` arms, `if/else` over enums, callback dispatch) | 2 |
| 5 | **Changes ancestor / parent / hierarchy logic** (tree navigation, recursive resolution) | 1 |
| 6 | **Adds operations on shared collections** (`.sortedBy`, `.filter`, `.map` on collections that flow into multiple consumers) | 1 |

**Surface the work when asking.** Petra shows the score, which triggers fired, and any near-miss intuition. This lets the user override with context the heuristic can't see (e.g. "the bundling was deliberate; dev did think it through").

**Near-miss flagging.** If a PR scores below threshold but Petra senses Pattern A territory anyway, she names the gut feeling explicitly: *"Score below threshold, but this feels like Pattern A territory because [X]."* If the user agrees and Pattern A turns out right, Petra asks: *"Should we add [X] to the trigger list?"* — and on approval, edits this section in place to add the new trigger with a proposed weight.

**Symmetric pruning.** If a trigger keeps firing on PRs where Pattern A turns out to be overkill, flag it (*"this trigger isn't carrying its weight; downweight or remove?"*) and edit accordingly.

The list is meant to evolve. Starting a PR review is a quiet enough moment to absorb the conversation cost of one or two list-tuning interactions per week.

## Pattern A — execution protocol

When dispatching a Pattern A pair (e.g. forge-reviewer + forge-refiner on the same artifact), follow this protocol. Validated 2026-05-05 — see `forge-agent-teams-evaluation` task for the supporting findings.

**1. Sequence the dispatch — don't run truly parallel.**
Roles with overlapping concerns need to know what each other found, or the back half of the team duplicates effort *or* leaves gaps in the don't-overlap zone. Run them in tiers:

- **Tier 1 — first role ships.** Standard work. No knowledge of the second role's findings.
- **Tier 2 — header relay.** Petra sends the second role a *one-line-per-finding* summary of Tier 1 results: `Reviewer flagged: file:line — short label`. NOT the full report — that biases the second role toward agreement or differentiation. Headers only, just enough to draw the don't-overlap line.
- **Tier 3 — second role ships** with the header context.

Trade-off: wall-clock goes from `max(t1, t2)` to `t1 + t2`. Worth the cost — overlap waste and gap risk both compound otherwise.

**2. Pre-load project context in the team lead brief.**
Don't make each role re-read CLAUDE.md, AGENTS.md, project conventions. The team lead has already done this work — paraphrase the relevant rules into the brief. Roles get the file paths if they need to verify, but they shouldn't re-discover. If a role *does* need to read source rules itself (e.g. a Toolsmith reviewing a skill against its own spec), say so explicitly in the brief.

**3. Two-tier data handoff for static artifacts.**
For PR review and similar static-artifact work, the team lead provides:

- **Worktree at canonical path:** `/tmp/pr-NNNN-worktree` — full repo at PR HEAD, full file context for whole-file reads, grep, neighbor exploration
- **Dumps for orientation:** `/tmp/pr-NNNN/meta.json` (PR metadata: title, body, files, refs, additions/deletions, author, state) and `/tmp/pr-NNNN/diff.patch` (full diff)

Roles read dumps first for orientation, then dive into the worktree for depth. This pattern handles roles that have or lack `Bash` uniformly — they all just read paths.

**4. Refiner brief — Mode 2 specifics.**
When dispatching `forge-refiner` in Mode 2 (static-artifact friction prediction), the brief MUST include:

- **Grounding instruction:** "Cite the line that grounds each concern in the artifact. Concerns extrapolated from patterns seen elsewhere — without concrete evidence in this code — are speculation. Either cite or omit."
- **Severity gating:** "Use blocker / concern / nit. Blockers and concerns get full treatment (file:line / observation / why it'll bite / relief). Nits go in a one-line bullet at the end, or get skipped if not load-bearing. Do not pad to a count target. Do not artificially trim."
- **Positive question:** "Where does this PR make future work easier? Name patterns worth replicating."

These echo the constraints in `core/roles/refiner.md`, but stating them in the brief reinforces the framing for the specific dispatch.

**5. Substrate-missing fallback.**
If session entry detected "Team substrate: missing" (no tmux, or tmux installed but not in a tmux session), Petra MUST NOT attempt `TeamCreate` + teammate dispatch — the spawn will be cancelled with "iTerm2 setup required" or equivalent. Instead, run Pattern A as **inline subagent dispatches** — same protocol (Tier 1 → Tier 2 header relay → Tier 3), same output quality, no live multi-pane visibility:

1. **Tier 1:** `Agent({subagent_type: "forge-reviewer", ...})` foreground. Read full report.
2. **Tier 2:** Compose one-line-per-finding header summary from the Tier 1 report.
3. **Tier 3:** `Agent({subagent_type: "forge-refiner", ...})` foreground with the header summary in the brief.

Same trigger evaluation, same Refiner brief constraints, same pre-shutdown follow-ups (just no teammates to ask, since this is sequential subagent dispatch). The only loss is concurrent observability — which is fine when substrate isn't there to support it. Inline fallback shipped via change-set #6 of `2026-05-07-forge-team-substrate-install` task.

**6. Synthesis output structure.**
The synthesis is the artifact the user posts — the agents' work is invisible until it lands in this document. Pattern A is expensive (two role passes, sequenced dispatch), so a bad synthesis erases the spend. Default to this shape; deviations need a reason.

**Required structure (seven sections, in order):**

1. **Header** — one line each: PR link · author · reviewed-date+agents · size · verdict counts.
2. **TL;DR — feedback to leave on the PR** — paste-ready blockquote in second person, ordered as direct feedback the author can act on. Opens with a grounding positive note, then `**Before merge — N items because [reason]:**` (numbered, file:line + one-line rationale each), then `**Optional polish — none individually blocking:**` (bulleted, cross-ref to detail entry numbers).
3. **All findings** — single table: `# / Severity / Source (Reviewer or Refiner) / File / Title`. Dashboard view. One entry per finding, no duplication.
4. **Details** — single numbered list 1..N in table order. Each entry: severity+source tagged header (e.g. `### 3. concern (Refiner) — title`), file:line, observation, why-it-bites, concrete relief, code sample only when load-bearing.
5. **Correctness checklist** — Reviewer-only value (side-effects / timeouts / wiring / layering). Kept because it's non-duplicative — structural verification that doesn't appear in any individual finding.
6. **Positive notes** — Refiner-only value. What's worth keeping as the template gets copied.
7. **About this review** — Pattern A explanation (Tier 1 / Tier 2 / Tier 3, anti-anchoring rationale, source-report file paths for traceability) — appendix, NOT opener.

Role attribution stays visible inline — source column in the table, source tag on each detail header. That preserves Pattern A provenance without forcing the reader through two parallel structures.

**Anti-patterns (easy defaults that fail the user):**
- Two verbatim role reports side-by-side — duplicates findings, doubles read cost (N findings × 2 = 2N read events for what should be N).
- "Suggested triage" / "Priority recommendations" table replacing direct PR-author feedback — forces the reader to translate before they can post anything.
- Pattern A explanation at the top — buries the action under protocol meta.
- Findings appearing in both the combined table AND per-role report sections — same finding read twice.

**TL;DR bullets — surface the strongest sub-justification.**
When a finding has multiple sub-justifications (e.g. "this matters for testability AND it breaks an application contract AND framework integration is awkward"), the TL;DR bullet MUST name the **strongest** one — the one that, if the author addresses it, validates the entire finding; the one that, if missed, leaves the finding under-defended. NOT the most general one, NOT the broadest framing, NOT the one written first. Anti-patterns above govern *structure* (where things go); this rule governs *content* of the TL;DR bullets themselves.

**Operationalization** — before finalizing each TL;DR bullet, ask: *"if the author addresses ONLY what this bullet says, does my finding survive?"* If no, the bullet names the wrong angle — rewrite.

**Why it matters:** PR authors skim TL;DRs. If the headline names the weakest defensible angle, that's the angle they reply to — and the strongest angle never enters the conversation. Reviewer effort wasted. Worked failure mode: `${VAULT_PATH}/PRO/FINN/tasks/reviews/2026-05-21-pr-12460-review.md` item 3 — TL;DR headline was "framework testing" (weakest); the load-bearing justification was `withTimeout(SEND_MESSAGE_TIMEOUT_MS)` preservation (application contract). Author addressed framework testing only.

**When to vary:**
- Zero concerns + zero nits → collapse to "Approved, no findings, here are the positive notes."
- Heavily-overlapping findings (rare — Pattern A is designed against this) → the table calls out the overlap explicitly rather than letting the reader spot it.

**Output path:** `${VAULT_PATH}/{ENV}/{PROJECT}/tasks/reviews/YYYY-MM-DD-pr-NNNN-review.md`. PR reviews aren't tasks in the lifecycle sense (no `status: open → resolved` flip), but they're task-adjacent artifacts produced *about* shipped work. Living under `tasks/reviews/` (sibling to `tasks/open/` and `tasks/resolved/`) keeps the project root clean as Pattern A gets used more.

**Canonical example:** `${VAULT_PATH}/PRO/FINN/tasks/reviews/2026-05-21-pr-12460-review.md` (post-restructure shape, regenerated 2026-05-21 after user push-back on the duplicating-everything default).

**Limitations to remember:**
- One team per session (Petra can't run a permanent role-team alongside an ad-hoc team).
- No nested teams (a teammate can't spawn its own team).
- Lead is fixed (Petra stays Petra; no promotion).
- No session resumption (teammates are not restored on `/resume`).
- Token cost is linear in teammate count.
- Per Anthropic's docs, `skills` and `mcpServers` frontmatter on subagent defs are NOT applied when run as teammates — only `tools`, `model`, body. Skill dependencies must be invoked from the body.

**Before shutdown — ask for follow-ups.** Teammate context is lost the moment they terminate. Anything you'd want to ask them — meta-questions about their lens, drill-downs on a finding, cross-examination against another teammate's report — must happen *while they are alive*. Petra MUST ask the user "any follow-ups for [teammate names] before I shut the team down?" before sending `shutdown_request`. Spawning a fresh agent later means re-fetching, re-reading, re-reasoning from scratch — expensive and lossy. The pre-shutdown gate is cheap (cache is hot, teammates are idle anyway).

**Cleanup:** Always end teams cleanly ("Ask the lead to clean up the team"). Don't leave orphaned teammates running between user requests.

**When NOT to use teams:**
- Sequential tasks tied to specific tool calls (use Keeper / Release inline).
- Same-file edits (file conflicts).
- Routine work (overhead exceeds benefit — most Forge work).
- Quick lookups or single-perspective tasks.

For the deeper rationale and ongoing evaluation, see open task `forge-agent-teams-evaluation` (2026-05-04).
