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

text = (adapter / "references/onboarding.md").read_text()
if '"${COPILOT_HOME:-$HOME/.copilot}/skills/forge-setup-models/scripts/forge-setup-models.sh"' not in text:
    raise SystemExit("onboarding reference: missing interactive setup command")
if '"/absolute/copilot/directory/scripts/forge-model-catalog.sh" check-coverage' not in text:
    raise SystemExit("onboarding reference: coverage check must use literal executable path")

skill = (adapter / "skills/forge/SKILL.md").read_text()
for fragment in (
    'Use the absolute parent directory of the `forge.conf` file',
    'never send',
    'an environment assignment, or a',
    '"/absolute/copilot/directory/skills/wellness-coach/scripts/wellness-reset.sh" --if-cold-start',
    'skills/wellness-coach/hooks/wellness_location.py file wellness-preferences.json',
    '/absolute/copilot/directory/scripts/forge-context.sh set-marker pending',
    '/absolute/copilot/directory/scripts/forge-model-catalog.sh onboarding-status',
    '--role keeper --snapshot /absolute/vault/path/_shared/model-catalog/catalog.json',
    'read that project\'s `current-checkpoint.md` for its recorded checkout path',
):
    if fragment not in skill:
        raise SystemExit(f"forge skill: missing literal-path entry contract: {fragment}")
for command in ("set-marker pending", "substrate-check", "weekly-wrap-line", "draft-invite-line"):
    if f'/absolute/copilot/directory/scripts/forge-context.sh {command}' not in skill:
        raise SystemExit(f"forge skill: missing literal command: {command}")
if 'forge-context.sh checkout-state "/absolute/recorded/checkout"' not in skill:
    raise SystemExit("forge skill: missing read-only checkout verification")
if re.search(r'`"\$COPILOT_DIR/scripts/forge-(?:context|model-catalog)\.sh" (?:set-marker|resolve|substrate-check|weekly-wrap-line|draft-invite-line)', skill):
    raise SystemExit("forge skill: variable-based entry command can bypass saved approvals")

entry = skill.split("### 2–6. Load Vault Context & Reconcile (Keeper Dispatch)", 1)[1].split("### 6. Present Context Summary", 1)[0]
dispatch = skill.split("**Subagent definitions + model tuning:**", 1)[1].split("## Agent-Teams Mode", 1)[0]
reference = (adapter / "references/subagent-models.md").read_text()
for label, text, fragments in (
    ("entry Keeper", entry, ("--role keeper", "dispatch_id", "`model`", "keep the", "marker pending", "do not", "inline fallback")),
    ("all Forge roles", dispatch, ("Before **every** Forge role dispatch", "entry Keeper", "team fan-out", "--role {role}", "dispatch_id", "`model`", "no_match", "invalid", "stop")),
    ("dispatch reference", reference, ('resolve --role keeper --snapshot', '"/absolute/copilot/directory/scripts/forge-model-catalog.sh"', "`resolved`", "`inherit`", "`no_match`", "`invalid`", "Do not dispatch")),
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
    "forge-context.sh checkout-state <project_path>",
    "For a scoped task or note edit, verify the changed file with Read",
    "Do not use",
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
[ "$("$tmp/default/.copilot/scripts/forge-context.sh")" = default ]
[ "$("$tmp/custom install/scripts/forge-context.sh")" = custom ]
mkdir -p "$tmp/vault/_shared" "$tmp/project with spaces"
printf 'VAULT_PATH=%s\n' "$tmp/vault" > "$tmp/forge.conf"
git -C "$tmp/project with spaces" init -q
root="$(git -C "$tmp/project with spaces" rev-parse --show-toplevel)"
script="$ROOT/adapters/copilot-cli/scripts/forge-context.sh"
state="$(HOME="$tmp/default" FORGE_CONF_OVERRIDE="$tmp/forge.conf" bash "$script" checkout-state "$tmp/project with spaces")"
[[ "$state" == *"Checkout: $root"* && "$state" == *"Git state: clean"* ]]
printf 'changed\n' > "$tmp/project with spaces/example.txt"
state="$(HOME="$tmp/default" FORGE_CONF_OVERRIDE="$tmp/forge.conf" bash "$script" checkout-state "$tmp/project with spaces")"
[[ "$state" == *"Git state: uncommitted changes"* && "$state" == *"example.txt"* ]]
! HOME="$tmp/default" FORGE_CONF_OVERRIDE="$tmp/forge.conf" bash "$script" checkout-state "$tmp/vault" >/dev/null 2>&1
echo PASS
