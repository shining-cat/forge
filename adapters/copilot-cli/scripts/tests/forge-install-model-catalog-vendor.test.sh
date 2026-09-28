#!/usr/bin/env bash
# Regression: install.sh (copilot-cli adapter) never vendored core/model_catalog/
# into the installed tooling. forge-model-catalog.sh's primary lookup is
# $COPILOT_DIR/scripts/model_catalog/cli.py (its PYTHONPATH fallback only
# resolves when run from inside the source repo). Without vendoring,
# `forge-model-catalog.sh resolve` fails on every real install with
# ModuleNotFoundError, silently breaking MODEL_TIER_* dispatch.
#
# Friction: 2026-09-28 — session-entry Keeper dispatch ran on the default
# model instead of the configured minimal tier; root-caused to this gap.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../../install.sh"
PASS=0; FAIL=0

ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1 — $2"; FAIL=$((FAIL+1)); }

[ -f "$INSTALL_SH" ] || { echo "  ✗ cannot locate install.sh at $INSTALL_SH"; exit 1; }

T="$(mktemp -d)"
mkdir -p "$T/home/.copilot"

HOME="$T/home" COPILOT_HOME="$T/home/.copilot" bash "$INSTALL_SH" --vault-path "$T/vault" >/dev/null 2>&1

if [ -f "$T/home/.copilot/scripts/model_catalog/cli.py" ] \
   && [ -f "$T/home/.copilot/scripts/model_catalog/catalog.py" ] \
   && [ -f "$T/home/.copilot/scripts/model_catalog/__init__.py" ]; then
  ok "core/model_catalog package vendored into installed scripts/model_catalog/"
else
  bad "vendoring" "missing files under $T/home/.copilot/scripts/model_catalog/"
fi

if [ -d "$T/home/.copilot/scripts/model_catalog/tests" ]; then
  bad "tests excluded" "model_catalog/tests/ should not be vendored, but exists"
else
  ok "model_catalog/tests/ excluded from vendoring"
fi

# End-to-end: resolve must no longer raise ModuleNotFoundError. A fresh,
# valid catalog + forge.conf are supplied so the only remaining failure mode
# under test is the import path, not catalog content/freshness.
mkdir -p "$T/vault/_shared/model-catalog"
cat > "$T/vault/_shared/model-catalog/catalog.json" <<'JSON'
{
  "schema_version": 1,
  "captured_at": "REPLACED_AT_RUNTIME",
  "clock": {"source": "manual", "timezone": "UTC"},
  "migration": {"status": "complete", "captured_at": "REPLACED_AT_RUNTIME"},
  "outcomes": [],
  "records": [
    {
      "identity": {"vendor": "Anthropic", "id": "claude-haiku-4.5"},
      "tier": "minimal",
      "capabilities": [],
      "evidence": [{"kind": "declared", "captured_at": "REPLACED_AT_RUNTIME"}],
      "bindings": [{"runtime": "copilot-cli", "active": true, "dispatch_id": "claude-haiku-4.5", "captured_at": "REPLACED_AT_RUNTIME"}]
    }
  ]
}
JSON
now_iso="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')"
sed -i '' "s/REPLACED_AT_RUNTIME/$now_iso/g" "$T/vault/_shared/model-catalog/catalog.json" 2>/dev/null \
  || sed -i "s/REPLACED_AT_RUNTIME/$now_iso/g" "$T/vault/_shared/model-catalog/catalog.json"

cat > "$T/home/.copilot/forge.conf" <<EOF
VAULT_PATH=$T/vault
MODEL_TIER_KEEPER=minimal
EOF

out="$(HOME="$T/home" COPILOT_DIR="$T/home/.copilot" VAULT_PATH="$T/vault" "$T/home/.copilot/scripts/forge-model-catalog.sh" resolve --role keeper 2>&1)"
if echo "$out" | grep -q "ModuleNotFoundError"; then
  bad "resolve works post-install" "still raises ModuleNotFoundError: $out"
else
  ok "resolve --role keeper runs without ModuleNotFoundError post-install"
fi

rm -rf "$T"
echo "── $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
