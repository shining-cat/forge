#!/usr/bin/env bash
# Test runner for forge-context.sh substrate-check
# Pure bash, no test framework dependency. Pattern follows forge-gap-since-last-signal.test.sh.
#
# Covers the three substrate states:
#  - $TMUX set (in tmux) → "Team substrate: ready"
#  - $TMUX unset, tmux installed → "missing — relaunch in tmux"
#  - $TMUX unset, tmux missing → "missing — install tmux"

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../forge-context.sh"

PASS=0
FAIL=0

assert_contains() {
  local name="$1"; local needle="$2"; local haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — output didn't contain: $needle"
    echo "    Got: $haystack"
    FAIL=$((FAIL+1))
  fi
}

# Make a temp vault stub so forge-context.sh's FORGE_CONF loader is happy.
mk_conf() {
  local vault; vault=$(mktemp -d)
  mkdir -p "$vault/_shared"
  local conf; conf=$(mktemp)
  cat >"$conf" <<EOF
VAULT_PATH=$vault
FORGE_REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
EOF
  echo "$conf"
}

# Drop tmux from PATH for the "tmux not installed" case. Builds a sandbox PATH
# made up of /usr/bin and /bin only minus any tmux binary.
sandbox_path_without_tmux() {
  local sand; sand=$(mktemp -d)
  for d in /usr/bin /bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      local name; name=$(basename "$f")
      [ "$name" = "tmux" ] && continue
      ln -sf "$f" "$sand/$name" 2>/dev/null || true
    done
  done
  echo "$sand"
}

echo "=== substrate-check ==="

CONF=$(mk_conf)

# Case 1: $TMUX set → ready
out=$(TMUX="/tmp/tmux-fake,1234,0" FORGE_CONF_OVERRIDE="$CONF" "$SCRIPT" substrate-check 2>&1)
assert_contains "TMUX set → ready" "Team substrate: ready" "$out"

# Case 2: $TMUX unset, tmux installed → "relaunch in tmux"
# Only run when tmux is actually installed on the host.
if command -v tmux >/dev/null 2>&1; then
  out=$(env -u TMUX FORGE_CONF_OVERRIDE="$CONF" "$SCRIPT" substrate-check 2>&1)
  assert_contains "TMUX unset + tmux installed → relaunch hint" "relaunch in tmux" "$out"
else
  echo "  ⊘ skipping 'tmux installed' case (tmux not on host)"
fi

# Case 3: $TMUX unset, tmux not on PATH → "install tmux"
sandbox=$(sandbox_path_without_tmux)
out=$(env -u TMUX PATH="$sandbox" FORGE_CONF_OVERRIDE="$CONF" "$SCRIPT" substrate-check 2>&1)
assert_contains "TMUX unset + tmux missing → install hint" "install tmux" "$out"
rm -rf "$sandbox"

echo
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
