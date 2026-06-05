#!/usr/bin/env bash
# Test runner for idle-sampler.py marker-gating.
# Pure bash, no test framework dependency.
# Pattern follows the forge-context.sh test files in
# adapters/claude-code/scripts/tests/.
#
# The script reads $HOME/.claude/forge.conf, $HOME/.claude/bin/screen_state,
# and writes to $HOME/.claude/wellness-idle-log.json — all via Path.home().
# We override HOME to a temp dir per test, drop a fake screen_state binary
# that always outputs "display=on,locked=0", set up the marker file under
# the configured VAULT_PATH, run the script, and inspect the idle log.
#
# Six marker states exercised, mirroring forge/SKILL.md step 1c semantics:
#   1. no forge.conf            → no-op
#   2. forge.conf, no VAULT_PATH → no-op
#   3. marker missing            → no-op
#   4. marker empty              → no-op
#   5. marker == "__pending__"   → no-op
#   6. marker valid JSON         → SAMPLES
#   7. marker legacy plain string → SAMPLES (backward-compat)
#   8. marker unreadable JSON    → no-op (defensive)

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLER="$SCRIPT_DIR/../idle-sampler.py"

PASS=0
FAIL=0

assert_no_sample() {
  local name="$1" log="$2"
  if [ ! -f "$log" ]; then
    echo "  ✓ $name (log file absent)"
    PASS=$((PASS+1))
    return
  fi
  local count
  count=$(python3 -c "import json,sys; d=json.load(open('$log')); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo "?")
  if [ "$count" = "0" ]; then
    echo "  ✓ $name (log empty)"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected no samples, got $count"
    FAIL=$((FAIL+1))
  fi
}

assert_sampled() {
  local name="$1" log="$2"
  if [ ! -f "$log" ]; then
    echo "  ✗ $name — expected a sample, log file missing"
    FAIL=$((FAIL+1))
    return
  fi
  local count
  count=$(python3 -c "import json,sys; d=json.load(open('$log')); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo "?")
  if [ "$count" -ge 1 ] 2>/dev/null; then
    echo "  ✓ $name ($count sample(s))"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected >=1 sample, got $count"
    FAIL=$((FAIL+1))
  fi
}

# Build a sandbox HOME with .claude/{bin/screen_state, forge.conf} and an
# optional VAULT_PATH containing _shared/. Returns the sandbox dir.
mk_sandbox() {
  local with_conf="$1" with_vault_path="$2"
  local home; home=$(mktemp -d)
  mkdir -p "$home/.claude/bin"
  # Fake screen_state binary: always reports display=on,locked=0
  cat > "$home/.claude/bin/screen_state" <<'EOF'
#!/bin/bash
echo "display=on,locked=0"
EOF
  chmod +x "$home/.claude/bin/screen_state"

  if [ "$with_conf" = "yes" ]; then
    if [ "$with_vault_path" = "yes" ]; then
      local vault="$home/vault"
      mkdir -p "$vault/_shared"
      echo "VAULT_PATH=$vault" > "$home/.claude/forge.conf"
    else
      echo "FORGE_REPO=/nope" > "$home/.claude/forge.conf"
    fi
  fi
  echo "$home"
}

run_sampler() {
  local home="$1"
  HOME="$home" python3 "$SAMPLER" 2>/dev/null || true
}

# Convenience: locate the idle log under a sandbox HOME.
log_path() { echo "$1/.claude/wellness-idle-log.json"; }

# Convenience: write a marker file with arbitrary content.
write_marker() {
  local home="$1" content="$2"
  echo -n "$content" > "$home/vault/_shared/forge-active"
}

echo "=== idle-sampler marker-gating ==="

# ── 1 — no forge.conf → no-op ──────────────────────────────────────────
echo ""
echo "Check 1 — no forge.conf → no-op"
HOME_DIR=$(mk_sandbox no no)
run_sampler "$HOME_DIR"
assert_no_sample "no forge.conf" "$(log_path "$HOME_DIR")"
rm -rf "$HOME_DIR"

# ── 2 — forge.conf without VAULT_PATH → no-op ──────────────────────────
echo ""
echo "Check 2 — forge.conf without VAULT_PATH → no-op"
HOME_DIR=$(mk_sandbox yes no)
run_sampler "$HOME_DIR"
assert_no_sample "no VAULT_PATH" "$(log_path "$HOME_DIR")"
rm -rf "$HOME_DIR"

# ── 3 — marker file missing → no-op ────────────────────────────────────
echo ""
echo "Check 3 — marker missing → no-op"
HOME_DIR=$(mk_sandbox yes yes)
# Don't create the marker.
run_sampler "$HOME_DIR"
assert_no_sample "marker missing" "$(log_path "$HOME_DIR")"
rm -rf "$HOME_DIR"

# ── 4 — marker empty → no-op ───────────────────────────────────────────
echo ""
echo "Check 4 — marker empty → no-op"
HOME_DIR=$(mk_sandbox yes yes)
write_marker "$HOME_DIR" ""
run_sampler "$HOME_DIR"
assert_no_sample "marker empty" "$(log_path "$HOME_DIR")"
rm -rf "$HOME_DIR"

# ── 5 — marker == "__pending__" → no-op ────────────────────────────────
echo ""
echo "Check 5 — marker == __pending__ → no-op"
HOME_DIR=$(mk_sandbox yes yes)
write_marker "$HOME_DIR" "__pending__"
run_sampler "$HOME_DIR"
assert_no_sample "marker pending" "$(log_path "$HOME_DIR")"
rm -rf "$HOME_DIR"

# ── 6 — marker valid JSON with session_id → SAMPLES ────────────────────
echo ""
echo "Check 6 — marker valid JSON with session_id → SAMPLES"
HOME_DIR=$(mk_sandbox yes yes)
write_marker "$HOME_DIR" '{"session_id":"abc","project":"demo","started_at":"2026-06-05T10:00:00+0200","tmux_pane":null}'
run_sampler "$HOME_DIR"
assert_sampled "marker active (JSON)" "$(log_path "$HOME_DIR")"
rm -rf "$HOME_DIR"

# ── 7 — legacy plain-string marker → SAMPLES (backward-compat) ─────────
echo ""
echo "Check 7 — legacy plain-string marker → SAMPLES"
HOME_DIR=$(mk_sandbox yes yes)
write_marker "$HOME_DIR" "forge"
run_sampler "$HOME_DIR"
assert_sampled "marker active (legacy plain string)" "$(log_path "$HOME_DIR")"
rm -rf "$HOME_DIR"

# ── 8 — marker has invalid JSON braces → no-op (defensive) ─────────────
# An attempted-JSON marker (starts with `{` but malformed) is treated as
# parse-error → no-op, not as legacy-plain-string. Otherwise a corrupted
# JSON write could silently re-enable sampling against the user's intent.
echo ""
echo "Check 8 — marker has malformed JSON → no-op (defensive)"
HOME_DIR=$(mk_sandbox yes yes)
write_marker "$HOME_DIR" '{"session_id":"abc",'
run_sampler "$HOME_DIR"
assert_no_sample "marker malformed JSON" "$(log_path "$HOME_DIR")"
rm -rf "$HOME_DIR"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
