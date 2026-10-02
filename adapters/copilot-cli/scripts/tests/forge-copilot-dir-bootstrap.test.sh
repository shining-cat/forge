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
    'matches `${COPILOT_HOME:-$HOME/.copilot}` (`-ef`)',
    'Otherwise use the self-contained `"${COPILOT_HOME:-$HOME/.copilot}/..."`',
    '"$COPILOT_DIR/skills/wellness-coach/scripts/wellness-reset.sh" --if-cold-start',
    '"$COPILOT_DIR/scripts/forge-context.sh" set-marker pending',
    '"$COPILOT_DIR/scripts/forge-model-catalog.sh" onboarding-status',
):
    if fragment not in skill:
        raise SystemExit(f"forge skill: missing guarded short command: {fragment}")
PY

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/default/.copilot/scripts" "$tmp/custom install/scripts"
printf '#!/bin/sh\nprintf "default\\n"\n' > "$tmp/default/.copilot/scripts/forge-context.sh"
printf '#!/bin/sh\nprintf "custom\\n"\n' > "$tmp/custom install/scripts/forge-context.sh"
chmod +x "$tmp/default/.copilot/scripts/forge-context.sh" "$tmp/custom install/scripts/forge-context.sh"
short_command='"$COPILOT_DIR/scripts/forge-context.sh"'
fallback_command='"${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-context.sh"'
guarded_command='if [ -n "${COPILOT_DIR:-}" ] && [ "$COPILOT_DIR" -ef "${COPILOT_HOME:-$HOME/.copilot}" ] && [ -x "$COPILOT_DIR/scripts/forge-context.sh" ]; then "$COPILOT_DIR/scripts/forge-context.sh"; else "${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-context.sh"; fi'
[ "$(env -u COPILOT_HOME HOME="$tmp/default" COPILOT_DIR="$tmp/default/.copilot" bash -c "$short_command")" = default ]
[ "$(env -u COPILOT_DIR -u COPILOT_HOME HOME="$tmp/default" bash -c "$fallback_command")" = default ]
[ "$(env -u COPILOT_DIR HOME="$tmp/default" COPILOT_HOME="$tmp/custom install" bash -c "$fallback_command")" = custom ]
[ "$(HOME="$tmp/default" COPILOT_HOME="$tmp/custom install" COPILOT_DIR="$tmp/custom install" bash -c "$short_command")" = custom ]
[ "$(env -u COPILOT_HOME HOME="$tmp/default" COPILOT_DIR="$tmp/default/.copilot" bash -c "$guarded_command")" = default ]
[ "$(env -u COPILOT_DIR HOME="$tmp/default" COPILOT_HOME="$tmp/custom install" bash -c "$guarded_command")" = custom ]
[ "$(HOME="$tmp/default" COPILOT_HOME="$tmp/custom install" COPILOT_DIR="$tmp/default/.copilot" bash -c "$guarded_command")" = custom ]
echo PASS
