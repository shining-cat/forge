#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="$SCRIPT_DIR/../statusline.sh"
input='{"model":{"display_name":"Example"},"workspace":{"current_dir":"/tmp/demo","project_dir":"/tmp/demo"},"cost":{"total_cost_usd":4.2,"total_duration_ms":12000}}'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export COPILOT_DIR="$TMP/copilot"
mkdir -p "$COPILOT_DIR/scripts" "$TMP/vault/_shared"
printf 'VAULT_PATH=%s\n' "$TMP/vault" > "$COPILOT_DIR/forge.conf"

output=$(printf '%s\n' "$input" | "$STATUSLINE")
printf 'active\n' > "$TMP/vault/_shared/forge-active"
printf '#!/bin/sh\necho "[Forge: demo]"\n' > "$COPILOT_DIR/scripts/forge-context.sh"
chmod +x "$COPILOT_DIR/scripts/forge-context.sh"
forge_output=$(printf '%s\n' "$input" | "$STATUSLINE")

for line in "$output" "$forge_output"; do
  [[ "$line" == *"Example"* && "$line" == *"12s"* ]] || {
    echo "statusline lost model or session timer" >&2
    exit 1
  }
  [[ "$line" != *"4.2"* && "$line" != *"💰"* ]] || {
    echo "statusline still shows estimated cost" >&2
    exit 1
  }
done
[[ "$forge_output" == *"[Forge: demo]"* ]] || {
  echo "active Forge statusline branch not exercised" >&2
  exit 1
}
