#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
python3 - "$ROOT/adapters/copilot-cli" <<'PY'
from pathlib import Path
import re
import sys

adapter = Path(sys.argv[1])
for folder in ("skills", "references"):
    for path in (adapter / folder).rglob("*.md"):
        fenced = False
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            if "$COPILOT_DIR/" not in line:
                continue
            if path == adapter / "skills/forge/SKILL.md":
                continue
            executable = (
                fenced and re.search(r'^\s*(?:bash\s+)?(?:\$COPILOT_DIR/|"\$COPILOT_DIR/|[A-Z_]+="\$COPILOT_DIR/)', line)
                or re.search(r'\b(?:run|call|invoke)\s+`(?:bash\s+)?\$COPILOT_DIR/', line, re.I)
            )
            if executable:
                raise SystemExit(f"{path}:{number}: command depends on COPILOT_DIR")

for name, command in (
    ("references/onboarding.md", "skills/forge-setup-models/scripts/forge-setup-models.sh"),
    ("references/subagent-models.md", "scripts/forge-model-catalog.sh"),
):
    text = (adapter / name).read_text()
    if f'"${{COPILOT_HOME:-$HOME/.copilot}}/{command}"' not in text:
        raise SystemExit(f"{name}: missing self-contained {command} command")

skill = (adapter / "skills/forge/SKILL.md").read_text()
for fragment in (
    'test -n "${COPILOT_DIR:-}" && test "$COPILOT_DIR" -ef "${COPILOT_HOME:-$HOME/.copilot}" && test -x "$COPILOT_DIR/skills/wellness-coach/scripts/wellness-reset.sh"',
    'If it fails, use the self-contained `"${COPILOT_HOME:-$HOME/.copilot}/..."`',
    '"$COPILOT_DIR/skills/wellness-coach/scripts/wellness-reset.sh" --if-cold-start',
    'skills/wellness-coach/hooks/wellness_location.py" file wellness-preferences.json',
    '"$COPILOT_DIR/scripts/forge-context.sh" set-marker pending',
    '"$COPILOT_DIR/scripts/forge-model-catalog.sh" onboarding-status',
    'read that project\'s `current-checkpoint.md` for its recorded checkout path',
):
    if fragment not in skill:
        raise SystemExit(f"forge skill: missing guarded short command: {fragment}")

entry = skill.split("### 2–6. Load Vault Context & Reconcile (Keeper Dispatch)", 1)[1].split("### 6. Present Context Summary", 1)[0]
dispatch = skill.split("**Subagent definitions + model tuning:**", 1)[1].split("## Agent-Teams Mode", 1)[0]
reference = (adapter / "references/subagent-models.md").read_text()
for label, text, fragments in (
    ("entry Keeper", entry, ("--role keeper", "dispatch_id", "`model`", "keep the", "marker pending", "do not", "inline fallback")),
    ("all Forge roles", dispatch, ("Before **every** Forge role dispatch", "entry Keeper", "team fan-out", "--role {role}", "dispatch_id", "`model`", "no_match", "invalid", "stop")),
    ("dispatch reference", reference, ('resolve --role keeper', '"${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-model-catalog.sh"', "`resolved`", "`inherit`", "`no_match`", "`invalid`", "Do not dispatch")),
):
    for fragment in fragments:
        if fragment not in text:
            raise SystemExit(f"{label}: missing model-tier dispatch contract: {fragment}")

for fragment in (
    "**Copilot parallelism check:**",
    "Copilot parallelism: available via /fleet",
    "Copilot parallelism: unverified",
    "Do not use `$TMUX` as a Copilot capability gate",
    "Claude-specific tmux/panes setup",
    "tmux-missing fallback do not apply to Copilot CLI",
):
    if fragment not in skill:
        raise SystemExit(f"forge skill: missing Copilot-native parallelism contract: {fragment}")
if "Team substrate: missing" in skill or "forge-context.sh\" teammate-notice" in skill:
    raise SystemExit("forge skill: stale Claude tmux readiness/notice contract")

keeper = (adapter / "agents/forge-keeper.agent.md").read_text()
for fragment in (
    "Use the supplied `project_path` for git verification",
    "read `wellness_preferences_path` as resolved",
    'Run `forge-calendar.sh entry-fetch` when the resolved preferences enable the calendar',
    'Treat a failed `review-sync` as an explicit gap',
):
    if fragment not in keeper:
        raise SystemExit(f"keeper: missing entry contract: {fragment}")
PY

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/default/.copilot/scripts" "$tmp/custom install/scripts"
mkdir -p "$tmp/default/.copilot/skills/wellness-coach/scripts" "$tmp/custom install/skills/wellness-coach/scripts"
printf '#!/bin/sh\nprintf "default\\n"\n' > "$tmp/default/.copilot/scripts/forge-context.sh"
printf '#!/bin/sh\nprintf "custom\\n"\n' > "$tmp/custom install/scripts/forge-context.sh"
touch "$tmp/default/.copilot/skills/wellness-coach/scripts/wellness-reset.sh" "$tmp/custom install/skills/wellness-coach/scripts/wellness-reset.sh"
chmod +x "$tmp/default/.copilot/scripts/forge-context.sh" "$tmp/custom install/scripts/forge-context.sh" "$tmp/default/.copilot/skills/wellness-coach/scripts/wellness-reset.sh" "$tmp/custom install/skills/wellness-coach/scripts/wellness-reset.sh"
short_command='"$COPILOT_DIR/scripts/forge-context.sh"'
fallback_command='"${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-context.sh"'
short_path_check='test -n "${COPILOT_DIR:-}" && test "$COPILOT_DIR" -ef "${COPILOT_HOME:-$HOME/.copilot}" && test -x "$COPILOT_DIR/skills/wellness-coach/scripts/wellness-reset.sh"'
[ "$(env -u COPILOT_HOME HOME="$tmp/default" COPILOT_DIR="$tmp/default/.copilot" bash -c "$short_command")" = default ]
[ "$(env -u COPILOT_DIR -u COPILOT_HOME HOME="$tmp/default" bash -c "$fallback_command")" = default ]
[ "$(env -u COPILOT_DIR HOME="$tmp/default" COPILOT_HOME="$tmp/custom install" bash -c "$fallback_command")" = custom ]
[ "$(HOME="$tmp/default" COPILOT_HOME="$tmp/custom install" COPILOT_DIR="$tmp/custom install" bash -c "$short_command")" = custom ]
env -u COPILOT_HOME HOME="$tmp/default" COPILOT_DIR="$tmp/default/.copilot" bash -c "$short_path_check"
HOME="$tmp/default" COPILOT_HOME="$tmp/custom install" COPILOT_DIR="$tmp/custom install" bash -c "$short_path_check"
! env -u COPILOT_DIR HOME="$tmp/default" bash -c "$short_path_check"
! HOME="$tmp/default" COPILOT_HOME="$tmp/custom install" COPILOT_DIR="$tmp/default/.copilot" bash -c "$short_path_check"
chmod -x "$tmp/default/.copilot/skills/wellness-coach/scripts/wellness-reset.sh"
! env -u COPILOT_HOME HOME="$tmp/default" COPILOT_DIR="$tmp/default/.copilot" bash -c "$short_path_check"
echo PASS
