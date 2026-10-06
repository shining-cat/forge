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

if [ -f "$T/home/.copilot/skills/forge-setup-models/SKILL.md" ] &&
   [ -f "$T/home/.copilot/skills/forge-setup-models/scripts/forge-setup-models.sh" ] &&
   [ -f "$T/home/.copilot/scripts/forge-model-catalog-setup.py" ] &&
   [ -f "$T/home/.copilot/skills/forge/references/onboarding.md" ]; then
  ok "manual setup skill, runnable script, backend and onboarding reference installed"
else
  bad "setup assets" "required onboarding files missing"
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

# Installed setup must use the packaged backend and leave runtime config intact.
cp "$T/home/.copilot/forge.conf" "$T/config-before"
setup="$T/home/.copilot/skills/forge-setup-models/scripts/forge-setup-models.sh"
if printf 'model-a\n\n1\n1\n1\n1\n' |
   HOME="$T/home" COPILOT_DIR="$T/home/.copilot" VAULT_PATH="$T/vault" FORGE_RUNTIME=copilot-cli bash "$setup" >/dev/null 2>&1 &&
   cmp -s "$T/config-before" "$T/home/.copilot/forge.conf" &&
   python3 "$T/home/.copilot/scripts/model_catalog/cli.py" check-coverage --snapshot "$T/vault/_shared/model-catalog/catalog.json" --binding copilot-cli >/dev/null; then
  ok "installed model setup maps four tiers without changing forge.conf"
else
  bad "installed setup" "mapping failed or changed forge.conf"
fi
cp "$T/vault/_shared/model-catalog/catalog.json" "$T/catalog-before"
if printf 'model-a\n\n9\n' |
   HOME="$T/home" COPILOT_DIR="$T/home/.copilot" VAULT_PATH="$T/vault" FORGE_RUNTIME=copilot-cli bash "$setup" >/dev/null 2>&1; then
  bad "invalid selection" "unexpected success"
elif cmp -s "$T/config-before" "$T/home/.copilot/forge.conf" &&
     cmp -s "$T/catalog-before" "$T/vault/_shared/model-catalog/catalog.json"; then
  ok "invalid installed mapping preserves both config and catalog"
else
  bad "invalid selection" "modified config or catalog"
fi

wrapper="$T/home/.copilot/scripts/forge-model-catalog.sh"
if HOME="$T/home" COPILOT_HOME="$T/home/.copilot" VAULT_PATH="$T/vault" \
   python3 - "$T/vault/_shared/model-catalog/catalog.json" "$T/home/.copilot/forge.conf" "$wrapper" <<'PY'
import copy
import json
import os
import subprocess
import sys

snapshot, config, wrapper = sys.argv[1:]
with open(snapshot, encoding="utf-8") as stream:
    catalog = json.load(stream)
minimal = next(record for record in catalog["records"] if record["tier"] == "minimal")
standard = copy.deepcopy(minimal)
standard["tier"] = "standard"
standard["identity"]["id"] = "reviewer-model"
standard["bindings"][0]["dispatch_id"] = "reviewer-model"
catalog["records"] = [minimal, standard]
with open(snapshot, "w", encoding="utf-8") as stream:
    json.dump(catalog, stream)
def set_tier(tier):
    with open(config, encoding="utf-8") as stream:
        lines = stream.readlines()
    lines = [f"MODEL_TIER_REVIEWER={tier}\n" if line.startswith("MODEL_TIER_REVIEWER=") else line
             for line in lines]
    if not any(line.startswith("MODEL_TIER_REVIEWER=") for line in lines):
        lines.append(f"MODEL_TIER_REVIEWER={tier}\n")
    with open(config, "w", encoding="utf-8") as stream:
        stream.writelines(lines)

set_tier("standard")
def check(role, code, status, model=None, snapshot_path=None):
    command = [wrapper, "resolve", "--role", role]
    if snapshot_path:
        command += ["--snapshot", snapshot_path]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    payload = json.loads(result.stdout)
    assert (result.returncode, payload["status"]) == (code, status), (result.returncode, payload)
    if model:
        assert payload["dispatch_id"] == model, payload
        assert payload["binding"]["runtime"] == "copilot-cli", payload

check("keeper", 0, "resolved", "model-a")
check("reviewer", 0, "resolved", "reviewer-model")
without_vault = dict(os.environ)
without_vault.pop("VAULT_PATH", None)
literal = subprocess.run(
    [wrapper, "resolve", "--role", "keeper", "--snapshot", snapshot],
    env=without_vault, capture_output=True, text=True, check=False)
assert literal.returncode == 0, literal.stdout + literal.stderr
assert json.loads(literal.stdout)["dispatch_id"] == "model-a", literal.stdout
missing = subprocess.run(
    [wrapper, "resolve", "--role", "keeper"],
    env=without_vault, capture_output=True, text=True, check=False)
assert missing.returncode == 3, missing.stdout + missing.stderr
assert json.loads(missing.stdout)["status"] == "invalid", missing.stdout
standard["bindings"][0]["active"] = False
with open(snapshot, "w", encoding="utf-8") as stream:
    json.dump(catalog, stream)
check("reviewer", 2, "no_match")
set_tier("not-a-tier")
check("reviewer", 3, "invalid")
set_tier("inherit")
check("reviewer", 1, "inherit", snapshot_path=snapshot + ".missing")
PY
then
  ok "role tiers resolve independently; absent, invalid, and inherit are distinct"
else
  bad "role dispatch resolution" "installed resolver violated the role-tier contract"
fi
cp "$T/config-before" "$T/home/.copilot/forge.conf"
cp "$T/catalog-before" "$T/vault/_shared/model-catalog/catalog.json"
# A mixed catalog resolves the local dispatch, not the foreign runtime's ID.
python3 - "$T/vault/_shared/model-catalog/catalog.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    catalog = json.load(stream)
for record in catalog["records"]:
    record["bindings"].insert(0, {"runtime": "claude", "active": True, "dispatch_id": "foreign-dispatch"})
with open(path, "w", encoding="utf-8") as stream:
    json.dump(catalog, stream)
PY
out="$(HOME="$T/home" COPILOT_HOME="$T/home/.copilot" VAULT_PATH="$T/vault" "$wrapper" resolve --role keeper)"
if echo "$out" | grep -q '"runtime": "copilot-cli"' &&
   echo "$out" | grep -q '"dispatch_id": "model-a"'; then
  ok "mixed-runtime resolve selects Copilot dispatch"
else
  bad "mixed-runtime resolve" "selected a foreign dispatch: $out"
fi
out="$(HOME="$T/home" COPILOT_HOME="$T/home/.copilot" VAULT_PATH="$T/vault" "$wrapper" check-coverage --snapshot "$T/vault/_shared/model-catalog/catalog.json")"
if echo "$out" | grep -q '"status": "complete"' &&
   echo "$out" | grep -q '"binding": "copilot-cli"'; then
  ok "coverage without binding uses Copilot runtime"
else
  bad "coverage without binding" "did not select Copilot runtime: $out"
fi
for args in "resolve --role keeper --binding claude" \
            "check-coverage --snapshot $T/vault/_shared/model-catalog/catalog.json --binding=claude" \
            "onboarding-status --snapshot $T/vault/_shared/model-catalog/catalog.json --config $T/home/.copilot/forge.conf --binding claude"; do
  out="$(HOME="$T/home" COPILOT_HOME="$T/home/.copilot" VAULT_PATH="$T/vault" "$wrapper" $args 2>&1)"
  rc=$?
  if [ "$rc" -eq 3 ] && echo "$out" | grep -q '"status":"invalid"'; then
    ok "foreign binding rejected: ${args%% *}"
  else
    bad "foreign binding" "accepted or misreported: $args ($rc): $out"
  fi
done
python3 - "$T/vault/_shared/model-catalog/catalog.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    catalog = json.load(stream)
catalog["records"][0]["bindings"][-1]["active"] = False
with open(path, "w", encoding="utf-8") as stream:
    json.dump(catalog, stream)
PY
out="$(HOME="$T/home" COPILOT_HOME="$T/home/.copilot" VAULT_PATH="$T/vault" "$wrapper" resolve --role keeper 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -q '"status": "no_match"'; then
  ok "foreign-only tier reports no match"
else
  bad "foreign-only tier" "did not fail closed ($rc): $out"
fi
cp "$T/catalog-before" "$T/vault/_shared/model-catalog/catalog.json"
# A full foreign mapping must never satisfy an incomplete local mapping.
python3 - "$T/vault/_shared/model-catalog/catalog.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    catalog = json.load(stream)
for record in catalog["records"]:
    record["bindings"].append({**record["bindings"][0], "runtime": "claude"})
catalog["records"][-1]["bindings"][0]["active"] = False
with open(path, "w", encoding="utf-8") as stream:
    json.dump(catalog, stream)
PY
if HOME="$T/home" "$wrapper" finish-onboarding --snapshot "$T/vault/_shared/model-catalog/catalog.json" --binding claude --config "$T/home/.copilot/forge.conf" >/dev/null 2>&1; then
  bad "mixed-runtime completion" "foreign coverage bypassed missing Copilot tier"
elif cmp -s "$T/config-before" "$T/home/.copilot/forge.conf"; then
  ok "mixed-runtime completion refuses foreign coverage"
else
  bad "mixed-runtime completion" "config was modified"
fi
cp "$T/catalog-before" "$T/vault/_shared/model-catalog/catalog.json"
if HOME="$T/home" "$wrapper" finish-onboarding --snapshot "$T/vault/_shared/model-catalog/catalog.json" --binding claude --config "$T/home/.copilot/forge.conf" >/dev/null 2>&1; then
  bad "foreign completion" "wrong-runtime coverage completed onboarding"
elif cmp -s "$T/config-before" "$T/home/.copilot/forge.conf"; then
  ok "foreign-runtime completion leaves config unchanged"
else
  bad "foreign completion" "config was modified"
fi
if HOME="$T/home" "$wrapper" finish-onboarding --snapshot "$T/vault/_shared/model-catalog/catalog.json" --binding copilot-cli --config "$T/home/.copilot/forge.conf" >/dev/null 2>&1; then
  cp "$T/config-before" "$T/config-expected"
  printf 'ONBOARDING_COMPLETE=true\n' >> "$T/config-expected"
  if cmp -s "$T/config-expected" "$T/home/.copilot/forge.conf"; then
    ok "installed final step changes only onboarding flag"
  else
    bad "final completion" "unexpected config change"
  fi
else
  bad "final completion" "valid coverage did not finish onboarding"
fi

# Custom COPILOT_HOME is an installer-supported location, independent of HOME.
custom_home="$T/home/custom-copilot"
mkdir -p "$custom_home" "$T/custom-vault/_shared/model-catalog"
if HOME="$T/home" COPILOT_HOME="$custom_home" bash "$INSTALL_SH" --vault-path "$T/custom-vault" >/dev/null 2>&1; then
  cp "$T/catalog-before" "$T/custom-vault/_shared/model-catalog/catalog.json"
  cp "$custom_home/forge.conf" "$T/custom-config-before"
  if printf 'model-a\n\n1\n1\n1\n1\n' |
     env -u COPILOT_DIR HOME="$T/home" COPILOT_HOME="$custom_home" VAULT_PATH="$T/custom-vault" FORGE_RUNTIME=copilot-cli \
       bash "$custom_home/skills/forge-setup-models/scripts/forge-setup-models.sh" >/dev/null 2>&1 &&
     cmp -s "$T/custom-config-before" "$custom_home/forge.conf" &&
     HOME="$T/home" COPILOT_HOME="$custom_home" "$custom_home/scripts/forge-model-catalog.sh" \
       finish-onboarding --snapshot "$T/custom-vault/_shared/model-catalog/catalog.json" \
       --binding copilot-cli --config "$custom_home/forge.conf" >/dev/null 2>&1; then
    sed 's/^ONBOARDING_COMPLETE=false$/ONBOARDING_COMPLETE=true/' "$T/custom-config-before" > "$T/custom-config-expected"
    if cmp -s "$T/custom-config-expected" "$custom_home/forge.conf"; then
      ok "custom COPILOT_HOME setup and completion preserve config"
    else
      bad "custom COPILOT_HOME" "completion changed other config keys"
    fi
  else
    bad "custom COPILOT_HOME" "setup or completion failed"
  fi
else
  bad "custom COPILOT_HOME" "install failed"
fi

rm -rf "$T"
echo "── $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
