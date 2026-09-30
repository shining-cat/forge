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
            executable = (
                fenced and re.search(r'^\s*(?:bash\s+)?(?:\$COPILOT_DIR/|"\$COPILOT_DIR/|[A-Z_]+="\$COPILOT_DIR/)', line)
                or re.search(r'\b(?:run|call|invoke)\s+`(?:bash\s+)?\$COPILOT_DIR/', line, re.I)
            )
            if executable:
                raise SystemExit(f"{path}:{number}: command depends on COPILOT_DIR")

for name, command in (
    ("skills/forge/SKILL.md", "scripts/forge-context.sh"),
    ("references/onboarding.md", "skills/forge-setup-models/scripts/forge-setup-models.sh"),
    ("references/subagent-models.md", "scripts/forge-model-catalog.sh"),
):
    text = (adapter / name).read_text()
    if f'"${{COPILOT_HOME:-$HOME/.copilot}}/{command}"' not in text:
        raise SystemExit(f"{name}: missing self-contained {command} command")
PY

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/default/.copilot/scripts" "$tmp/custom install/scripts"
printf '#!/bin/sh\nprintf "default\\n"\n' > "$tmp/default/.copilot/scripts/forge-context.sh"
printf '#!/bin/sh\nprintf "custom\\n"\n' > "$tmp/custom install/scripts/forge-context.sh"
chmod +x "$tmp/default/.copilot/scripts/forge-context.sh" "$tmp/custom install/scripts/forge-context.sh"
command='"${COPILOT_HOME:-$HOME/.copilot}/scripts/forge-context.sh"'
[ "$(env -u COPILOT_DIR -u COPILOT_HOME HOME="$tmp/default" bash -c "$command")" = default ]
[ "$(env -u COPILOT_DIR HOME="$tmp/default" COPILOT_HOME="$tmp/custom install" bash -c "$command")" = custom ]
echo PASS
