#!/bin/bash
# Interactive, user-owned model bindings; never infer tier from model name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_RUNTIME="${FORGE_RUNTIME:-copilot-cli}"
case "$FORGE_RUNTIME" in
  claude) COPILOT_DIR="${CLAUDE_DIR:-$HOME/.claude}" ;;
  copilot-cli) COPILOT_DIR="${COPILOT_DIR:-${COPILOT_HOME:-$HOME/.copilot}}" ;;
  *) echo "Error: FORGE_RUNTIME must be claude or copilot-cli" >&2; exit 1 ;;
esac
VAULT_PATH="${VAULT_PATH:-$(grep '^VAULT_PATH=' "$COPILOT_DIR/forge.conf" 2>/dev/null | cut -d= -f2-)}"
[[ -n "$VAULT_PATH" ]] || { echo "Error: VAULT_PATH is required" >&2; exit 1; }
if [[ -n "${FORGE_CORE:-}" ]]; then
  SETUP_PY="$FORGE_CORE/tools/forge-model-catalog-setup.py"
  CATALOG_CLI="$FORGE_CORE/model_catalog/cli.py"
elif [[ -f "$COPILOT_DIR/scripts/forge-model-catalog-setup.py" ]]; then
  SETUP_PY="$COPILOT_DIR/scripts/forge-model-catalog-setup.py"
  if [[ "$FORGE_RUNTIME" == claude ]]; then
    CATALOG_CLI="$COPILOT_DIR/scripts/forge_capability/cli.py"
  else
    CATALOG_CLI="$COPILOT_DIR/scripts/model_catalog/cli.py"
  fi
else
  FORGE_ROOT="$(cd "$SCRIPT_DIR/../../../../" && pwd)"
  SETUP_PY="$FORGE_ROOT/core/tools/forge-model-catalog-setup.py"
  CATALOG_CLI="$FORGE_ROOT/core/model_catalog/cli.py"
fi
[[ -f "$SETUP_PY" && -f "$CATALOG_CLI" ]] || { echo "Error: model setup tools are not installed" >&2; exit 1; }
[[ -f "$COPILOT_DIR/forge.conf" ]] || { echo "Error: forge.conf is missing" >&2; exit 1; }
python3 "$SETUP_PY" --runtime "$FORGE_RUNTIME" --cli "$CATALOG_CLI" \
  --catalog "$VAULT_PATH/_shared/model-catalog/catalog.json"
