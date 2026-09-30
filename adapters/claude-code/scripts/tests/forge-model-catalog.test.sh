#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/_shared" "$tmp/home/.claude/scripts/forge_capability"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s' "{\"schema_version\":1,\"captured_at\":\"$now\",\"clock\":{\"source\":\"manual\",\"timezone\":\"UTC\"},\"records\":[],\"outcomes\":[],\"migration\":{}}" > "$tmp/_shared/capability-snapshot.json"
cp "$ROOT/core/model_catalog/"*.py "$tmp/home/.claude/scripts/forge_capability/"
set +e
out=$(HOME="$tmp/home" VAULT_PATH="$tmp" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" --tier inherit); rc=$?
set -e
[ "$rc" = 1 ] && echo "$out" | grep -q inherit
printf '%s\n' 'MODEL_KEEPER=premium' 'MODEL_IMPL=' 'OTHER=value' > "$tmp/forge.conf"
HOME="$tmp/home" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" migrate --config "$tmp/forge.conf" >/dev/null
grep -q 'MODEL_TIER_KEEPER=premium' "$tmp/forge.conf"
grep -q 'MODEL_TIER_IMPL=inherit' "$tmp/forge.conf"
test -f "$tmp/forge.conf.pre-model-catalog"
cat > "$tmp/_shared/capability-snapshot.json" <<JSON
{"schema_version":1,"captured_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","clock":{"source":"manual","timezone":"UTC"},"records":[{"identity":{"id":"model","vendor":"vendor"},"tier":"premium","capabilities":[],"evidence":[{"kind":"declared"}],"bindings":[{"runtime":"claude","active":true,"dispatch_id":"dispatch"}]}],"outcomes":[],"migration":{"status":"complete"}}
JSON
set +e
resolved=$(HOME="$tmp/home" VAULT_PATH="$tmp" FORGE_CONF="$tmp/forge.conf" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" resolve --role keeper)
rc=$?
set -e
[ "$rc" = 0 ] && echo "$resolved" | grep -q '"status": "resolved"'
python3 - "$tmp/_shared/capability-snapshot.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    catalog = json.load(stream)
catalog["records"][0]["bindings"].insert(0, {"runtime": "copilot-cli", "active": True, "dispatch_id": "foreign-dispatch"})
with open(path, "w", encoding="utf-8") as stream:
    json.dump(catalog, stream)
PY
resolved=$(HOME="$tmp/home" VAULT_PATH="$tmp" FORGE_CONF="$tmp/forge.conf" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" resolve --role keeper)
echo "$resolved" | grep -q '"dispatch_id": "dispatch"'
echo "$resolved" | grep -q '"runtime": "claude"'
set +e
foreign=$(HOME="$tmp/home" VAULT_PATH="$tmp" FORGE_CONF="$tmp/forge.conf" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" resolve --role keeper --binding=copilot-cli); rc=$?
set -e
[ "$rc" = 3 ] && echo "$foreign" | grep -q '"status":"invalid"'
set +e
coverage=$(HOME="$tmp/home" VAULT_PATH="$tmp" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" check-coverage --snapshot "$tmp/_shared/capability-snapshot.json"); rc=$?
set -e
[ "$rc" = 2 ] && echo "$coverage" | grep -q '"binding": "claude"'
set +e
foreign=$(HOME="$tmp/home" VAULT_PATH="$tmp" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" check-coverage --snapshot "$tmp/_shared/capability-snapshot.json" --binding copilot-cli); rc=$?
set -e
[ "$rc" = 3 ] && echo "$foreign" | grep -q '"status":"invalid"'
set +e
foreign=$(HOME="$tmp/home" VAULT_PATH="$tmp" FORGE_CONF="$tmp/forge.conf" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" onboarding-status --snapshot "$tmp/_shared/capability-snapshot.json" --config "$tmp/forge.conf" --binding=copilot-cli); rc=$?
set -e
[ "$rc" = 3 ] && echo "$foreign" | grep -q '"status":"invalid"'
python3 - "$tmp/_shared/capability-snapshot.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    catalog = json.load(stream)
catalog["records"][0]["bindings"][-1]["active"] = False
with open(path, "w", encoding="utf-8") as stream:
    json.dump(catalog, stream)
PY
set +e
missing=$(HOME="$tmp/home" VAULT_PATH="$tmp" FORGE_CONF="$tmp/forge.conf" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" resolve --role keeper); rc=$?
set -e
[ "$rc" = 2 ] && echo "$missing" | grep -q '"status": "no_match"'
# Explicit tier overrides migrated role tier.
set +e
HOME="$tmp/home" VAULT_PATH="$tmp" FORGE_CONF="$tmp/forge.conf" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" resolve --role keeper --tier economy >/dev/null
rc=$?
set -e
[ "$rc" = 2 ]
printf '%s' "{\"schema_version\":1,\"captured_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"clock\":{\"source\":\"manual\",\"timezone\":\"UTC\"},\"records\":[],\"outcomes\":[{\"status\":\"bad\"}],\"migration\":{\"status\":\"none\"}}" > "$tmp/_shared/capability-snapshot.json"
set +e
invalid=$(HOME="$tmp/home" VAULT_PATH="$tmp" "$ROOT/adapters/claude-code/scripts/forge-model-catalog.sh" resolve --tier premium)
rc=$?
set -e
[ "$rc" = 3 ] && echo "$invalid" | grep -q '"status": "invalid"'
echo PASS
