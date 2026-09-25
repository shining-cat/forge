#!/bin/bash
# Non-interactive model catalog setup for testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COPILOT_DIR="${COPILOT_DIR:-$HOME/.copilot}"
VAULT_PATH="${VAULT_PATH:-$(grep '^VAULT_PATH=' "$COPILOT_DIR/forge.conf" 2>/dev/null | cut -d= -f2)}"

# Resolve path to core tool
if [[ -n "${FORGE_CORE:-}" ]]; then
    SETUP_PY="$FORGE_CORE/tools/forge-model-catalog-setup.py"
elif [[ -d "$COPILOT_DIR/forge/core/tools" ]]; then
    SETUP_PY="$COPILOT_DIR/forge/core/tools/forge-model-catalog-setup.py"
else
    # Development mode: derive from script location
    # SCRIPT_DIR is at: .../forge/core/skills/forge-setup-models/scripts
    # Go up 4 levels to reach the root
    FORGE_ROOT="$(cd "$SCRIPT_DIR/../../../../" && pwd)"
    SETUP_PY="$FORGE_ROOT/core/tools/forge-model-catalog-setup.py"
fi

if [[ -z "$VAULT_PATH" ]]; then
    echo "Error: VAULT_PATH not found in $COPILOT_DIR/forge.conf" >&2
    exit 1
fi

CATALOG_DIR="$VAULT_PATH/_shared/model-catalog"
CATALOG_FILE="$CATALOG_DIR/catalog.json"

# Ensure catalog directory exists
mkdir -p "$CATALOG_DIR"

# Usage: pass model list as argument or via stdin
if [[ $# -gt 0 ]]; then
    MODELS_INPUT="$@"
else
    MODELS_INPUT=$(cat)
fi

# Parse and build catalog
python3 "$SETUP_PY" parse <<< "$MODELS_INPUT" | python3 << 'PYTHON_BUILD'
import json
import sys
from datetime import datetime

models = json.load(sys.stdin)
records = []
now = datetime.now(datetime.timezone.utc).isoformat()

for model in models:
    model_id = model["id"]
    vendor = model["vendor"] or "Unknown"
    tier = model["inferred_tier"] or "standard"
    
    record = {
        "identity": {"vendor": vendor, "id": model_id},
        "tier": tier,
        "capabilities": [],
        "evidence": [{"kind": "manual", "captured_at": now, "source": "setup"}],
        "bindings": [{"runtime": "copilot-cli", "active": True, "dispatch_id": model_id, "captured_at": now}],
    }
    records.append(record)

catalog = {
    "schema_version": 1,
    "clock": {"source": "manual", "timezone": "UTC", "captured_at": now},
    "records": records,
}

print(json.dumps(catalog, indent=2))
PYTHON_BUILD
