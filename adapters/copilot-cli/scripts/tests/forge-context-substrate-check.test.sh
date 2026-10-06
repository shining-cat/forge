#!/usr/bin/env bash
# Test runner for forge-context.sh substrate-check
# Pure bash, no test framework dependency. Pattern follows forge-gap-since-last-signal.test.sh.
#
# Covers native CLI availability with and without tmux.

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

# Build a PATH without Copilot, regardless of the host's installation path.
sandbox_path_without_copilot() {
  local sand; sand=$(mktemp -d)
  for d in /usr/bin /bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] || continue
      local name; name=$(basename "$f")
      [ "$name" = "copilot" ] && continue
      ln -sf "$f" "$sand/$name" 2>/dev/null || true
    done
  done
  echo "$sand"
}

echo "=== substrate-check ==="

CONF=$(mk_conf)
sandbox=$(sandbox_path_without_copilot)
mkdir -p "$sandbox/with-copilot"
printf '#!/bin/sh\nexit 0\n' > "$sandbox/with-copilot/copilot"
chmod +x "$sandbox/with-copilot/copilot"

for tmux_state in unset set; do
  for cli_state in available unavailable; do
    if [ "$cli_state" = available ]; then
      test_path="$sandbox/with-copilot:$sandbox"
      expected="Copilot parallelism: available via /fleet (tmux not required; tmux-pane teams not implied)"
    else
      test_path="$sandbox"
      expected="Copilot parallelism: unverified — copilot executable not on PATH; check the CLI launch before parallel dispatch"
    fi
    if [ "$tmux_state" = set ]; then
      out=$(TMUX="/tmp/tmux-fake,1234,0" PATH="$test_path" FORGE_CONF_OVERRIDE="$CONF" "$SCRIPT" substrate-check 2>&1)
    else
      out=$(env -u TMUX PATH="$test_path" FORGE_CONF_OVERRIDE="$CONF" "$SCRIPT" substrate-check 2>&1)
    fi
    assert_contains "Copilot $cli_state; TMUX $tmux_state" "$expected" "$out"
  done
done
rm -rf "$sandbox"

echo
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
