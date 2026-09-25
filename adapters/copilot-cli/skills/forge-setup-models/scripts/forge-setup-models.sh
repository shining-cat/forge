#!/bin/bash
# Interactive model catalog setup for Forge

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
    # SCRIPT_DIR is at: .../forge/adapters/copilot-cli/skills/forge-setup-models/scripts
    # Go up 5 levels to reach the root
    FORGE_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
    SETUP_PY="$FORGE_ROOT/core/tools/forge-model-catalog-setup.py"
fi

if [[ -z "$VAULT_PATH" ]]; then
    echo "Error: VAULT_PATH not found in $COPILOT_DIR/forge.conf" >&2
    exit 1
fi

CATALOG_DIR="$VAULT_PATH/_shared/model-catalog"
CATALOG_FILE="$CATALOG_DIR/catalog.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure catalog directory exists
mkdir -p "$CATALOG_DIR"

# ============================================================================
# STEP 1: Input discovery
# ============================================================================

echo -e "${BLUE}=== Forge Model Catalog Setup ===${NC}"
echo ""
echo "Paste your available models from your org's settings page."
echo "Format: one per line, or comma-separated"
echo "Example:"
echo "  claude-opus-5"
echo "  claude-sonnet-5"
echo "  gpt-5.6-luna"
echo "  gemini-3.8-flash"
echo ""
echo "Press Ctrl+D when done (or paste, then press Enter twice):"
echo ""

# Read user input
MODELS_INPUT=$(cat)

if [[ -z "$MODELS_INPUT" ]]; then
    echo -e "${RED}No models provided. Exiting.${NC}"
    exit 1
fi

# ============================================================================
# STEP 2: Parse & infer
# ============================================================================

echo ""
echo -e "${BLUE}Parsing models...${NC}"

# Call Python to parse models
MODELS_JSON=$(python3 "$SETUP_PY" parse <<< "$MODELS_INPUT" 2>&1) || {
    echo -e "${RED}Error parsing models${NC}" >&2
    exit 1
}

# Count models
MODEL_COUNT=$(echo "$MODELS_JSON" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")

if [[ $MODEL_COUNT -eq 0 ]]; then
    echo -e "${RED}No valid models found. Exiting.${NC}"
    exit 1
fi

echo -e "${GREEN}Found $MODEL_COUNT model(s)${NC}"
echo ""

# ============================================================================
# STEP 3: Interactive tier assignment
# ============================================================================

echo -e "${BLUE}=== Tier Assignment ===${NC}"
echo "Forge uses 3 neutral tiers:"
echo "  economy   — lightweight, fast, cost-optimized (e.g., Haiku, Flash)"
echo "  standard  — balanced capability (e.g., Sonnet, GPT-5.4)"
echo "  premium   — full-strength reasoning (e.g., Opus, GPT-5.6, Luna)"
echo ""

RECORDS=()
SKIPPED_MODELS=()

echo "$MODELS_JSON" | python3 << 'PYTHON_LOOP'
import json
import sys

models = json.load(sys.stdin)
for model in models:
    model_id = model["id"]
    vendor = model["vendor"] or "Unknown"
    inferred_tier = model["inferred_tier"] or "unknown"
    
    print(f"\n{model_id} ({vendor})")
    print(f"  Inferred tier: {inferred_tier}")
PYTHON_LOOP

echo ""
echo "For each model, I'll ask you to confirm the tier."
echo ""

# Collect tier assignments interactively
# Convert JSON to bash arrays for processing
MODELS_ARRAY=()
while IFS= read -r line; do
    MODELS_ARRAY+=("$line")
done < <(echo "$MODELS_JSON" | python3 -c "import sys, json; [print(json.dumps(m)) for m in json.load(sys.stdin)]")

for MODEL_JSON in "${MODELS_ARRAY[@]}"; do
    MODEL=$(echo "$MODEL_JSON" | python3 -c "import sys, json; m = json.load(sys.stdin); print(m['id'])")
    VENDOR=$(echo "$MODEL_JSON" | python3 -c "import sys, json; m = json.load(sys.stdin); print(m['vendor'] or 'Unknown')")
    INFERRED=$(echo "$MODEL_JSON" | python3 -c "import sys, json; m = json.load(sys.stdin); print(m['inferred_tier'] or 'unknown')")
    
    # Ask user for tier
    echo -n "Assign tier for $MODEL ($VENDOR) [$INFERRED]: "
    read -r TIER_INPUT
    
    # Use inferred if user just pressed enter
    if [[ -z "$TIER_INPUT" ]]; then
        TIER="$INFERRED"
    else
        TIER="$TIER_INPUT"
    fi
    
    # Validate tier
    if [[ ! "$TIER" =~ ^(economy|standard|premium)$ ]]; then
        echo -e "${YELLOW}Invalid tier '$TIER', skipping $MODEL${NC}"
        SKIPPED_MODELS+=("$MODEL")
        continue
    fi
    
    # Ask if should be dispatch candidate
    echo -n "Use $MODEL as active dispatch? [Y/n]: "
    read -r DISPATCH_INPUT
    
    if [[ "$DISPATCH_INPUT" =~ ^[nN] ]]; then
        DISPATCH_ID=""
    else
        DISPATCH_ID="$MODEL"
    fi
    
    # Build record JSON
    RECORD=$(python3 << PYTHON_REC
import json
from datetime import datetime

now = datetime.utcnow().isoformat() + "Z"
record = {
    "identity": {
        "vendor": "$VENDOR",
        "id": "$MODEL",
    },
    "tier": "$TIER",
    "capabilities": [],
    "evidence": [
        {
            "kind": "manual",
            "captured_at": now,
            "source": "user-setup",
        }
    ],
    "bindings": [
        {
            "runtime": "copilot-cli",
            "active": $([[ -n "$DISPATCH_ID" ]] && echo "true" || echo "false"),
            "dispatch_id": "$DISPATCH_ID",
            "captured_at": now,
        }
    ],
}
print(json.dumps(record))
PYTHON_REC
)
    
    RECORDS+=("$RECORD")
done

echo ""
if [[ ${#SKIPPED_MODELS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Skipped: ${SKIPPED_MODELS[*]}${NC}"
fi

if [[ ${#RECORDS[@]} -eq 0 ]]; then
    echo -e "${RED}No valid records. Exiting.${NC}"
    exit 1
fi

# ============================================================================
# STEP 4: Build catalog
# ============================================================================

echo -e "${BLUE}Building catalog...${NC}"

# Build JSON array of records
RECORDS_JSON="["
for i in "${!RECORDS[@]}"; do
    RECORDS_JSON+="${RECORDS[$i]}"
    if [[ $i -lt $((${#RECORDS[@]} - 1)) ]]; then
        RECORDS_JSON+=","
    fi
done
RECORDS_JSON+="]"

# Build complete catalog
CATALOG=$(python3 << PYTHON_CAT
import json
from datetime import datetime

now = datetime.utcnow()

records = json.loads("""$RECORDS_JSON""")

catalog = {
    "schema_version": 1,
    "clock": {
        "source": "manual",
        "timezone": "UTC",
        "captured_at": now.isoformat() + "Z",
    },
    "records": records,
}

print(json.dumps(catalog, indent=2))
PYTHON_CAT
)

# ============================================================================
# STEP 5: Validate schema
# ============================================================================

echo -e "${BLUE}Validating schema...${NC}"

# Write to temp file and validate
TEMP_CATALOG=$(mktemp)
echo "$CATALOG" > "$TEMP_CATALOG"

if python3 "$SETUP_PY" validate "$TEMP_CATALOG" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Schema valid${NC}"
else
    echo -e "${RED}✗ Schema validation failed${NC}"
    python3 "$SETUP_PY" validate "$TEMP_CATALOG" >&2 || true
    rm -f "$TEMP_CATALOG"
    exit 1
fi

# ============================================================================
# STEP 6: Test resolve
# ============================================================================

echo ""
echo -e "${BLUE}Testing resolve() for each tier...${NC}"

RESOLVE_RESULTS=$(python3 "$SETUP_PY" resolve-test "$TEMP_CATALOG")

echo "$RESOLVE_RESULTS" | python3 << 'PYTHON_RESOLVE'
import json
import sys

results = json.load(sys.stdin)

for tier, result in results.items():
    if result.get("success"):
        dispatch_id = result.get("dispatch_id")
        print(f"  ✓ {tier:12} → {dispatch_id}")
    else:
        error = result.get("error", "unknown")
        print(f"  ✗ {tier:12} → {error}")
PYTHON_RESOLVE

# Check if all resolutions passed
FAILED=$(echo "$RESOLVE_RESULTS" | python3 -c "import sys, json; r = json.load(sys.stdin); print(sum(1 for v in r.values() if not v.get('success')))")

if [[ $FAILED -gt 0 ]]; then
    echo -e "${RED}Some tiers failed resolve test. Check tier assignments.${NC}"
    rm -f "$TEMP_CATALOG"
    exit 1
fi

# ============================================================================
# STEP 7: Write canonical catalog
# ============================================================================

echo ""
echo -e "${BLUE}Writing canonical catalog...${NC}"

cp "$TEMP_CATALOG" "$CATALOG_FILE"
rm -f "$TEMP_CATALOG"

echo -e "${GREEN}✓ Catalog saved to $CATALOG_FILE${NC}"
echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Verify the catalog: \`cat $CATALOG_FILE | jq .\`"
echo "  2. Test resolve: \`forge-model-catalog resolve --role keeper --tier standard\`"
echo "  3. Use in Forge: Sonnet main-loop, Opus for hard work"
