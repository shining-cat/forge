# Wellness Cold-Start Check — internals

Background for the `### 0a. Wellness Cold-Start Check` step in `SKILL.md`. The step itself is one bash invocation; everything below is rationale for *when* and *why* — only matters when debugging the cold-start flow, modifying it, or onboarding a new adapter.

## What the script does

```bash
~/.claude/skills/wellness-coach/scripts/wellness-reset.sh --if-cold-start
```

The script self-gates on `WELLNESS_ENABLED` + `WELLNESS_COLD_START_HOURS` (defaults: disabled, 4h) read from `~/.claude/forge.conf`, and internally invokes `forge-gap-since-last-signal.sh`.

- On a cold start (gap ≥ threshold) it runs a full wellness reset and prints a single line: *"Wellness reset — Forge idle for {Nh}h{Mm}m, break clock zeroed."*
- Otherwise it's silent (exit 0, no stdout).

The SKILL step says "surface stdout verbatim before the step-6 summary" — don't paraphrase, don't omit.

## Why this is step 0a, not step 2.5

If the user has returned after a long gap with an active strike (e.g. ☕ break overdue from the prior session), the strike fires on the FIRST tool call of the new session. Step 0's Read of `~/.claude/forge.conf` is that first call — without 0a, it gets blocked, and the user sees the wellness coach on strike instead of Petra warming the anvil.

`wellness-reset.sh` is on the strike-exemption list (path matches `/.claude/skills/wellness-coach/scripts/`), so it runs cleanly even when a strike is active, and clears the strike in the process. After 0a runs, step 0's Read proceeds normally.

## Why the gap script doesn't need to be exempted

The internal `forge-gap-since-last-signal.sh` call is shell-to-shell (the wellness script invokes it directly), bypassing the Claude tool layer entirely. So the gap script does not need to be on the strike exemption list — it never goes through PreToolUse.

## Daemon gating (2026-06-05)

The `idle-sampler` launchd agent (`com.claude.wellness-idle-sampler`, installed by `wellness-coach/scripts/install-monitor.sh`) wakes every 60s. Since 2026-06-05 it's **gated on the forge-active marker** at the script level: each tick reads `${VAULT_PATH}/_shared/forge-active` and exits early when no Forge session is active. The launchd timer keeps running; no samples land in the log between sessions.

This aligns with the user principle *"Forge should not behave as if it monitors when not running"* — the cold-start reset (Step 0a above) handles the visible leak of timestamps, this gate handles the underlying always-on substrate.

**Marker states the daemon honors** (mirror of `forge/SKILL.md` step 1c):

| Marker state | Daemon behavior |
|-------------|-----------------|
| File missing | no-op |
| File empty / whitespace-only | no-op |
| File contains literal `__pending__` | no-op (Forge launching, no project chosen yet) |
| Valid JSON with `session_id` | **sample** (canonical post-2026-04 format) |
| Legacy plain-string project name | **sample** (backward-compat) |
| Looks like JSON but malformed | no-op (defensive — better to lose a tick than silently re-enable) |
| Read errors | no-op (same rationale) |

### Verification recipe

```bash
# 1. Marker absent → no sampling (cleanest test: while Forge is off)
NOW=$(date +%s); sleep 90
jq --argjson now "$NOW" '[.[] | select(.t > $now)] | length' \
  ~/.claude/wellness-idle-log.json
# Expect: 0  (or "file not found" if it's never been written)

# 2. Marker active → sampling
~/.claude/scripts/forge-context.sh set-marker active forge
NOW=$(date +%s); sleep 90
jq --argjson now "$NOW" '[.[] | select(.t > $now)] | length' \
  ~/.claude/wellness-idle-log.json
# Expect: >= 1

# 3. Marker __pending__ → no sampling (regression guard for the disambiguation window)
~/.claude/scripts/forge-context.sh set-marker pending
NOW=$(date +%s); sleep 90
jq --argjson now "$NOW" '[.[] | select(.t > $now)] | length' \
  ~/.claude/wellness-idle-log.json
# Expect: 0
```

Automated test (8 marker-state checks) lives at `adapters/claude-code/modules/wellness-coach/scripts/tests/idle-sampler.test.sh`.

## See also

- [[wellness-awareness.md]] — Petra ↔ wellness coach boundary (Petra reads state; coach knows nothing about Forge)
- [[lifecycle.md]] — full session lifecycle (entry → checkpoint → exit) for which 0a is step 1 in time order
