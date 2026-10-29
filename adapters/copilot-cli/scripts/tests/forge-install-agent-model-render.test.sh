#!/usr/bin/env bash
# install.sh bakes each role's resolved model into the installed agent
# definitions (frontmatter `model:`), so the tier binding holds on any dispatch
# that omits `model`. Re-installing must not churn backups, and a remap must
# show up as drift until re-rendered.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$SCRIPT_DIR/../../install.sh"
CORE="$SCRIPT_DIR/../../../../core"
PASS=0; FAIL=0

ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1 — $2"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
HOME_DIR="$T/home"; COP="$HOME_DIR/.copilot"; VAULT="$T/vault"
mkdir -p "$COP"
run_install() { HOME="$HOME_DIR" COPILOT_HOME="$COP" bash "$INSTALL_SH" --vault-path "$VAULT" "$@" 2>&1; }
model_of() { awk 'NR>1 && /^---$/ {exit} /^model:/ {print; exit}' "$COP/agents/forge-$1.agent.md"; }

out="$(run_install)"
if [ -z "$(model_of keeper)" ] && grep -q "No model catalog yet" <<<"$out"; then
  ok "no catalog: install succeeds and leaves agents without a model line"
else
  bad "no-catalog install" "$out"
fi

mkdir -p "$VAULT/_shared/model-catalog"
PYTHONPATH="$CORE" python3 - "$VAULT/_shared/model-catalog/catalog.json" <<'PY'
import sys
from model_catalog.catalog import write_snapshot
from model_catalog.tests.test_catalog import rec, snap
def b(i): return [{"runtime": "copilot-cli", "active": True, "dispatch_id": i}]
write_snapshot(snap([rec("s", "minimal", bindings=b("small-1")), rec("m", "standard", bindings=b("mid-1")),
                     rec("p", "premium", bindings=b("big-1")), rec("e", "economy", bindings=b("tiny-1"))]), sys.argv[1])
PY
cat >> "$COP/forge.conf" <<'EOF'
MODEL_TIER_KEEPER=minimal
MODEL_TIER_ARCHITECT=premium
MODEL_TIER_REVIEWER=standard
MODEL_TIER_IMPL=inherit
EOF

run_install >/dev/null
[ "$(model_of keeper)" = "model: small-1" ] && ok "keeper gets its minimal-tier model" || bad "keeper" "$(model_of keeper)"
[ "$(model_of architect)" = "model: big-1" ] && ok "architect gets its premium-tier model" || bad "architect" "$(model_of architect)"
[ -z "$(model_of impl)" ] && ok "inherit role gets no model line" || bad "impl" "$(model_of impl)"

before="$(find "$COP/agents" -name '*.pre-update.*' | wc -l | tr -d ' ')"
sleep 1; run_install >/dev/null
after="$(find "$COP/agents" -name '*.pre-update.*' | wc -l | tr -d ' ')"
[ "$before" = "$after" ] && ok "re-install creates no extra agent backups" || bad "backup churn" "$before -> $after"

sed -i.bak 's/^MODEL_TIER_KEEPER=.*/MODEL_TIER_KEEPER=standard/' "$COP/forge.conf"; rm -f "$COP/forge.conf.bak"
HOME="$HOME_DIR" COPILOT_HOME="$COP" "$COP/scripts/forge-model-catalog.sh" render-agents \
  --snapshot "$VAULT/_shared/model-catalog/catalog.json" --src-dir "$COP/agents" --check >/dev/null
[ "$?" = 5 ] && ok "remap is reported as drift (exit 5)" || bad "drift" "expected exit 5"
HOME="$HOME_DIR" COPILOT_HOME="$COP" "$COP/scripts/forge-model-catalog.sh" render-agents \
  --snapshot "$VAULT/_shared/model-catalog/catalog.json" --src-dir "$COP/agents" >/dev/null
[ "$(model_of keeper)" = "model: mid-1" ] && ok "re-render applies the remap" || bad "re-render" "$(model_of keeper)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
