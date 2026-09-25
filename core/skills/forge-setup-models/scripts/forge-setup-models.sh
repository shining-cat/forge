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
    # Follow symlinks to get the canonical path
    REAL_SCRIPT="$(cd "$SCRIPT_DIR" && pwd -P)"
    # REAL_SCRIPT is at: .../forge/core/skills/forge-setup-models/scripts
    # Go up 4 levels to reach the root
    FORGE_ROOT="$(cd "$REAL_SCRIPT/../../../../" && pwd)"
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
echo "Paste your available model IDs from your org's settings page."
echo "Format: one per line, or comma-separated (use model IDs, NOT product names)"
echo ""
echo "Valid model IDs:"
echo "  claude-haiku-4.5, claude-opus-5, claude-sonnet-5"
echo "  gpt-5.4, gpt-5.6-luna, gpt-5.6-sol, gpt-5.6-terra"
echo "  gpt-6-luna, gpt-6-sol"
echo "  gemini-3.8-flash"
echo "  kimi-k2.7-code, kimi-k3"
echo ""
echo "Do NOT paste product names like:"
echo "  ✗ Anthropic Claude Haiku 4.5  (use: claude-haiku-4.5)"
echo "  ✗ Copilot CLI  (not a model)"
echo ""

# Read models: piped input goes until EOF, TTY input expects blank line terminator
MODELS_INPUT=""

if [[ ! -t 0 ]]; then
    # Input is piped: read until EOF
    MODELS_INPUT=$(cat)
else
    # Input is TTY: interactive prompt with blank-line terminator
    echo "Press Ctrl+D when done (or paste, then press Enter twice):"
    echo ""
    
    while IFS= read -r line; do
        # Blank line signals end of models
        if [[ -z "$line" ]]; then
            break
        fi
        MODELS_INPUT+="$line"$'\n'
    done
    
    # Remove trailing newline
    MODELS_INPUT="${MODELS_INPUT%$'\n'}"
fi

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

# Count models and check for "unknown" entries
MODEL_COUNT=$(echo "$MODELS_JSON" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")
UNKNOWN_COUNT=$(echo "$MODELS_JSON" | python3 -c "import sys, json; data = json.load(sys.stdin); print(sum(1 for m in data if m.get('inferred_tier') == 'unknown'))")

if [[ $MODEL_COUNT -eq 0 ]]; then
    echo -e "${RED}No valid models found. Exiting.${NC}"
    exit 1
fi

echo -e "${GREEN}Found $MODEL_COUNT model(s)${NC}"

if [[ $UNKNOWN_COUNT -gt 0 ]]; then
    echo -e "${YELLOW}⚠️  Warning: $UNKNOWN_COUNT model(s) not recognized${NC}"
    echo -e "${YELLOW}   This usually means you pasted product names instead of model IDs.${NC}"
    echo -e "${YELLOW}   Model ID format: claude-haiku-4.5, gpt-5.6-luna, kimi-k3, etc.${NC}"
    echo ""
fi

echo ""

# ============================================================================
# STEP 3: Interactive tier assignment
# ============================================================================

echo -e "${BLUE}=== Tier Assignment ===${NC}"
echo "Forge uses 4 tiers:"
echo "  minimal   — ultra-lightweight tasks (e.g., Haiku)"
echo "  economy   — lightweight, fast, cost-optimized (e.g., Flash)"
echo "  standard  — balanced capability (e.g., Sonnet, GPT-5.4)"
echo "  premium   — full-strength reasoning (e.g., Opus, GPT-5.6, Luna)"
echo ""

RECORDS=()

MODELS_TMPFILE=$(mktemp)
printf '%s\n' "$MODELS_JSON" > "$MODELS_TMPFILE"

echo ""
echo "Pick one model for each tier."
echo ""

# Group models by inferred tier
echo -e "${BLUE}Analyzing models...${NC}"
python3 << PYTHON_GROUP > "$MODELS_TMPFILE.groups"
import json
import sys

with open("$MODELS_TMPFILE", "r") as f:
    models = json.load(f)

# Group by tier
tiers = {
    "minimal": [],
    "economy": [],
    "standard": [],
    "premium": [],
}

for model in models:
    tier = model.get("inferred_tier") or "unknown"
    if tier in tiers:
        tiers[tier].append(model)

# Write grouping to stderr for display
for tier in ["minimal", "economy", "standard", "premium"]:
    candidates = tiers[tier]
    if candidates:
        print(f"\n{tier.upper()}:", file=sys.stderr)
        for i, m in enumerate(candidates, 1):
            print(f"  {i}. {m['id']} ({m.get('vendor', 'Unknown')})", file=sys.stderr)
    else:
        print(f"\n{tier.upper()}: (no models inferred)", file=sys.stderr)

# Write JSON grouping for shell to read
import json
print(json.dumps({
    "minimal": tiers["minimal"],
    "economy": tiers["economy"],
    "standard": tiers["standard"],
    "premium": tiers["premium"],
}))
PYTHON_GROUP

echo ""

# Collect tier-to-model assignments
TIER_MODELS=()  # Will store: TIER|MODEL_ID|VENDOR|INFERRED_TIER
TIERS_ARRAY=("minimal" "economy" "standard" "premium")

for TIER in "${TIERS_ARRAY[@]}"; do
    # Extract candidates for this tier from JSON grouping
    CANDIDATES_JSON=$(python3 -c "import json; data = json.load(open('$MODELS_TMPFILE.groups')); print(json.dumps(data['$TIER']))")
    CANDIDATES_COUNT=$(python3 -c "import json; data = json.load(open('$MODELS_TMPFILE.groups')); print(len(data['$TIER']))")
    
    if [[ "$CANDIDATES_COUNT" -eq 0 ]]; then
        echo -e "${YELLOW}No models inferred for $TIER tier.${NC}" >&2
        echo -n "Enter a model ID manually (or press Enter to skip): " >&2
        read -r MANUAL_MODEL < /dev/tty || MANUAL_MODEL=""
        
        if [[ -z "$MANUAL_MODEL" ]]; then
            echo -e "${YELLOW}Skipped $TIER tier${NC}"
            continue
        fi
        
        # Validate manual entry exists in full list
        FOUND=$(python3 -c "import json; models = json.load(open('$MODELS_TMPFILE')); m = [x for x in models if x['id'] == '$MANUAL_MODEL']; print(json.dumps(m[0]) if m else 'null')")
        if [[ "$FOUND" == "null" ]]; then
            echo -e "${RED}Model not found: $MANUAL_MODEL${NC}"
            continue
        fi
        CHOICE_JSON="$FOUND"
    else
        # Show candidates and prompt
        echo -e "${BLUE}[$TIER]${NC}" >&2
        python3 << PYTHON_SHOW
import json
data = json.load(open('$MODELS_TMPFILE.groups'))
for i, m in enumerate(data['$TIER'], 1):
    print(f'  {i}. {m["id"]} ({m.get("vendor", "Unknown")})', file=__import__('sys').stderr)
PYTHON_SHOW
        
        echo -n "Pick one (enter number or model ID): " >&2
        read -r PICK_INPUT < /dev/tty || PICK_INPUT=""
        
        if [[ -z "$PICK_INPUT" ]]; then
            echo -e "${YELLOW}Skipped $TIER tier${NC}"
            continue
        fi
        
        # Parse input: either a number or a model ID
        if [[ "$PICK_INPUT" =~ ^[0-9]+$ ]]; then
            # Number input: extract from candidates
            IDX=$((PICK_INPUT - 1))
            CHOICE_JSON=$(python3 -c "import json; data = json.load(open('$MODELS_TMPFILE.groups')); candidates = data['$TIER']; print(json.dumps(candidates[$IDX]) if 0 <= $IDX < len(candidates) else 'null')")
            if [[ "$CHOICE_JSON" == "null" ]]; then
                echo -e "${RED}Invalid selection${NC}"
                continue
            fi
        else
            # Model ID input: look up in full list
            CHOICE_JSON=$(python3 -c "import json; models = json.load(open('$MODELS_TMPFILE')); m = [x for x in models if x['id'] == '$PICK_INPUT']; print(json.dumps(m[0]) if m else 'null')")
            if [[ "$CHOICE_JSON" == "null" ]]; then
                echo -e "${RED}Model not found: $PICK_INPUT${NC}"
                continue
            fi
            
            # Check if this model belongs to a different tier
            INFERRED_TIER=$(python3 -c "import json; m = json.loads('$CHOICE_JSON'); print(m.get('inferred_tier', 'unknown'))")
            if [[ "$INFERRED_TIER" != "$TIER" ]] && [[ "$INFERRED_TIER" != "unknown" ]]; then
                echo -e "${YELLOW}Warning: $PICK_INPUT inferred as $INFERRED_TIER, but you're assigning to $TIER${NC}" >&2
                echo -n "Confirm? [y/N]: " >&2
                read -r CONFIRM < /dev/tty || CONFIRM=""
                if [[ ! "$CONFIRM" =~ ^[yY] ]]; then
                    echo "Skipped"
                    continue
                fi
            fi
        fi
    fi
    
    # Extract model info and store
    MODEL_ID=$(python3 -c "import json; m = json.loads('$CHOICE_JSON'); print(m['id'])")
    VENDOR=$(python3 -c "import json; m = json.loads('$CHOICE_JSON'); print(m.get('vendor', 'Unknown'))")
    INFERRED=$(python3 -c "import json; m = json.loads('$CHOICE_JSON'); print(m.get('inferred_tier', 'unknown'))")
    
    echo -e "  Selected: ${GREEN}$MODEL_ID${NC} ($VENDOR) for $TIER"
    TIER_MODELS+=("$TIER|$MODEL_ID|$VENDOR|$INFERRED")
done

echo ""
if [[ ${#TIER_MODELS[@]} -eq 0 ]]; then
    echo -e "${RED}No models selected. Exiting.${NC}"
    exit 1
fi

# ============================================================================
# STEP 3: Build records from tier assignments
# ============================================================================

echo -e "${BLUE}Building records...${NC}"

for TIER_ASSIGNMENT in "${TIER_MODELS[@]}"; do
    IFS='|' read -r TIER MODEL_ID VENDOR INFERRED <<< "$TIER_ASSIGNMENT"
    
    # Build record JSON
    RECORD=$(python3 << PYTHON_REC
import json
from datetime import datetime, timezone

now = datetime.now(timezone.utc).isoformat()
record = {
    "identity": {
        "vendor": "$VENDOR",
        "id": "$MODEL_ID",
    },
    "tier": "$TIER",
    "capabilities": [],
    "evidence": [
        {
            "kind": "declared",
            "captured_at": now,
        }
    ],
    "bindings": [
        {
            "runtime": "copilot-cli",
            "active": True,
            "dispatch_id": "$MODEL_ID",
            "captured_at": now,
        }
    ],
}
print(json.dumps(record))
PYTHON_REC
)
    
    RECORDS+=("$RECORD")
done

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
from datetime import datetime, timezone

now = datetime.now(timezone.utc).isoformat()

records = json.loads("""$RECORDS_JSON""")

catalog = {
    "schema_version": 1,
    "captured_at": now,
    "clock": {
        "source": "manual",
        "timezone": "UTC",
    },
    "migration": {
        "status": "complete",
        "captured_at": now,
    },
    "outcomes": [],
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
# STEP 6: Verify tier coverage
# ============================================================================

echo ""
echo -e "${BLUE}Verifying tier coverage...${NC}"

python3 << PYTHON_VERIFY
import json
import sys

catalog = json.loads("""$CATALOG""")

tier_coverage = {}
for record in catalog.get("records", []):
    tier = record.get("tier")
    if tier not in tier_coverage:
        tier_coverage[tier] = []
    tier_coverage[tier].append(record["identity"]["id"])

for tier in ["minimal", "economy", "standard", "premium"]:
    models = tier_coverage.get(tier, [])
    if models:
        model_list = ", ".join(models)
        print(f"  ✓ {tier:12} → {model_list}")
    else:
        print(f"  ✗ {tier:12} → (no model assigned)")
PYTHON_VERIFY


# ============================================================================
# STEP 7: Write canonical catalog
# ============================================================================

echo ""
echo -e "${BLUE}Writing canonical catalog...${NC}"

cp "$TEMP_CATALOG" "$CATALOG_FILE"
rm -f "$TEMP_CATALOG"

echo -e "${GREEN}✓ Catalog saved to $CATALOG_FILE${NC}"
echo ""

# ============================================================================
# STEP 8: Migrate forge.conf with role-to-tier assignments
# ============================================================================

echo -e "${BLUE}Migrating forge.conf with role-to-tier assignments...${NC}"

# Role-to-tier assignment (locked per model tiering design)
# KEEPER → minimal (orchestration, checkpoint writes, index updates)
# ARCHITECT → premium (design/tradeoffs)
# REVIEWER, RELEASE, IMPL, REFINER, DEBUGGER, TOOLSMITH → standard

ROLE_TIERS=(
    "KEEPER:minimal"
    "ARCHITECT:premium"
    "REVIEWER:standard"
    "RELEASE:standard"
    "IMPL:standard"
    "REFINER:standard"
    "DEBUGGER:standard"
    "TOOLSMITH:standard"
)

# Build a backup of forge.conf if it doesn't exist
FORGE_CONF_BAK="${COPILOT_DIR}/forge.conf.bak.$(date +%s)"
if [[ -f "$COPILOT_DIR/forge.conf" ]]; then
    cp "$COPILOT_DIR/forge.conf" "$FORGE_CONF_BAK"
fi

# Migrate forge.conf: add or update MODEL_TIER_* keys
for ROLE_TIER in "${ROLE_TIERS[@]}"; do
    ROLE="${ROLE_TIER%%:*}"
    TIER="${ROLE_TIER##*:}"
    KEY="MODEL_TIER_${ROLE}"
    
    if grep -q "^${KEY}=" "$COPILOT_DIR/forge.conf" 2>/dev/null; then
        # Update existing key
        sed -i.tmp "s/^${KEY}=.*/${KEY}=${TIER}/" "$COPILOT_DIR/forge.conf"
        rm -f "$COPILOT_DIR/forge.conf.tmp"
    else
        # Append new key
        echo "${KEY}=${TIER}" >> "$COPILOT_DIR/forge.conf"
    fi
done

echo -e "${GREEN}✓ forge.conf migrated${NC}"
if [[ -f "$FORGE_CONF_BAK" ]]; then
    echo "  Backup saved: $FORGE_CONF_BAK"
fi

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Verify the catalog: \`cat $CATALOG_FILE | jq .\`"
echo "  2. Test resolve: \`forge-model-catalog resolve --role keeper\`"
echo "  3. Use in Forge: entry ceremony runs on Keeper role (minimal tier)"
