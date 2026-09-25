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
echo "Forge uses 3 neutral tiers:"
echo "  economy   — lightweight, fast, cost-optimized (e.g., Haiku, Flash)"
echo "  standard  — balanced capability (e.g., Sonnet, GPT-5.4)"
echo "  premium   — full-strength reasoning (e.g., Opus, GPT-5.6, Luna)"
echo ""

RECORDS=()
SKIPPED_MODELS=()

MODELS_TMPFILE=$(mktemp)
printf '%s\n' "$MODELS_JSON" > "$MODELS_TMPFILE"

python3 << PYTHON_LOOP
import json
import os
import sys

models_file = "$MODELS_TMPFILE"
if not os.path.exists(models_file):
    print(f"ERROR: File not found: {models_file}", file=sys.stderr)
    sys.exit(1)

with open(models_file, "r") as f:
    models = json.load(f)
for model in models:
    model_id = model.get("id", "MISSING")
    vendor = model.get("vendor") or "Unknown"
    inferred_tier = model.get("inferred_tier") or "unknown"
    
    print(f"\n{model_id} ({vendor})")
    print(f"  Inferred tier: {inferred_tier}")
PYTHON_LOOP

echo ""
echo "For each model, I'll ask you to confirm the tier."
echo ""

# Collect tier assignments interactively
# Extract models to a separate temp file (one JSON object per line)
MODELS_LINES_TMPFILE=$(mktemp)
python3 << MODELS_EXTRACT > "$MODELS_LINES_TMPFILE"
import json

with open("$MODELS_TMPFILE", "r") as f:
    models = json.load(f)
    for model in models:
        print(json.dumps(model))
MODELS_EXTRACT

LINES_COUNT=$(wc -l < "$MODELS_LINES_TMPFILE")
echo -e "${BLUE}[DEBUG] Extracted $LINES_COUNT model lines to process${NC}" >&2

# Now iterate over the extracted models
while IFS= read -r MODEL_JSON; do
    [[ -z "$MODEL_JSON" ]] && continue
    
    MODEL=$(echo "$MODEL_JSON" | python3 -c "import sys, json; m = json.load(sys.stdin); print(m['id'])")
    VENDOR=$(echo "$MODEL_JSON" | python3 -c "import sys, json; m = json.load(sys.stdin); print(m['vendor'] or 'Unknown')")
    INFERRED=$(echo "$MODEL_JSON" | python3 -c "import sys, json; m = json.load(sys.stdin); print(m['inferred_tier'] or 'unknown')")
    
    echo -e "${BLUE}[Processing $MODEL]${NC}" >&2
    
    # Ask user for tier (read from /dev/tty to ensure interactive input)
    echo -n "Assign tier for $MODEL ($VENDOR) [$INFERRED]: " >&2
    read -r TIER_INPUT < /dev/tty || TIER_INPUT=""
    
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
    
    # Ask if should be dispatch candidate (read from /dev/tty)
    echo -n "Use $MODEL as active dispatch? [Y/n]: " >&2
    read -r DISPATCH_INPUT < /dev/tty || DISPATCH_INPUT=""
    
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
            "kind": "declared",
            "captured_at": now,
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
