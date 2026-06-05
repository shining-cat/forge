#!/usr/bin/env bash
# Test runner for wellness-timer.py's should_defer_for_meeting() helper.
# Pure bash + python3, no test framework dependency. Mirrors the test pattern
# from adapters/claude-code/modules/wellness-coach/scripts/tests/.
#
# Strategy: stub ~/.claude/scripts/forge-calendar.sh under a temp HOME with
# canned outputs, then invoke the helper via python3 importing wellness-timer.py
# under the canonical hook location (we import the source-of-truth file, not
# the installed copy, so changes to canonical land in tests immediately).
#
# Five cases:
#   1. in-meeting returns content       → defer=True, reason mentions title + remaining min
#   2. in-meeting empty, next-meeting <5min returns content → defer=True, reason mentions imminent
#   3. both empty                       → defer=False
#   4. forge-calendar.sh missing        → defer=False (graceful)
#   5. calendar script timeout / crash  → defer=False (graceful)

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_FILE="$SCRIPT_DIR/../wellness-timer.py"

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — expected '$expected', got '$actual'"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  ✓ $name"
    PASS=$((PASS+1))
  else
    echo "  ✗ $name — output didn't contain '$needle'"
    echo "    Got: $haystack"
    FAIL=$((FAIL+1))
  fi
}

# Build a sandbox HOME with ~/.claude/scripts/ and an optional fake calendar
# script. $1 = what to plant: "in-meeting", "imminent", "empty", "missing",
# "crashing".
mk_sandbox() {
  local mode="$1"
  local home; home=$(mktemp -d)
  mkdir -p "$home/.claude/scripts"
  local sh="$home/.claude/scripts/forge-calendar.sh"

  case "$mode" in
    missing)
      # No script — exercise the "file not found" graceful branch.
      ;;
    in-meeting)
      cat > "$sh" <<'EOF'
#!/bin/bash
case "$1" in
  in-meeting)  echo "All Hands|42" ;;
  next-meeting) echo "" ;;
esac
EOF
      chmod +x "$sh"
      ;;
    imminent)
      cat > "$sh" <<'EOF'
#!/bin/bash
case "$1" in
  in-meeting)   echo "" ;;
  next-meeting) echo "14:00|Standup|3" ;;
esac
EOF
      chmod +x "$sh"
      ;;
    empty)
      cat > "$sh" <<'EOF'
#!/bin/bash
# Both subcommands silent — user is free
exit 0
EOF
      chmod +x "$sh"
      ;;
    crashing)
      cat > "$sh" <<'EOF'
#!/bin/bash
echo "[forge-calendar] gws auth expired" >&2
exit 3
EOF
      chmod +x "$sh"
      ;;
  esac
  echo "$home"
}

# Run the helper in a sandboxed HOME. Capture "defer|reason" on stdout.
run_helper() {
  local home="$1"
  HOME="$home" python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('wt', '$HOOK_FILE')
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)
defer, reason = wt.should_defer_for_meeting()
print(f'{defer}|{reason}')
" 2>/dev/null
}

echo "=== wellness-timer should_defer_for_meeting ==="

# ── 1 — in-meeting returns content → defer=True ─────────────────────────
echo ""
echo "Check 1 — in-meeting → defer=True with title + remaining"
HOME_DIR=$(mk_sandbox in-meeting)
out=$(run_helper "$HOME_DIR")
assert_eq    "defer flag" "True" "${out%%|*}"
assert_contains "reason mentions title"     "All Hands"  "$out"
assert_contains "reason mentions remaining" "42 min"     "$out"
rm -rf "$HOME_DIR"

# ── 2 — imminent next-meeting → defer=True ──────────────────────────────
echo ""
echo "Check 2 — imminent next-meeting → defer=True with title + minutes-until"
HOME_DIR=$(mk_sandbox imminent)
out=$(run_helper "$HOME_DIR")
assert_eq    "defer flag" "True" "${out%%|*}"
assert_contains "reason mentions title"           "Standup"     "$out"
assert_contains "reason mentions minutes-until"   "3 min"       "$out"
rm -rf "$HOME_DIR"

# ── 3 — both empty → defer=False ────────────────────────────────────────
echo ""
echo "Check 3 — both subcommands silent → defer=False"
HOME_DIR=$(mk_sandbox empty)
out=$(run_helper "$HOME_DIR")
assert_eq "defer flag" "False" "${out%%|*}"
assert_eq "reason empty" ""    "${out#*|}"
rm -rf "$HOME_DIR"

# ── 4 — script missing → defer=False (graceful) ─────────────────────────
echo ""
echo "Check 4 — forge-calendar.sh missing → defer=False"
HOME_DIR=$(mk_sandbox missing)
out=$(run_helper "$HOME_DIR")
assert_eq "defer flag" "False" "${out%%|*}"
rm -rf "$HOME_DIR"

# ── 5 — script crashes (e.g. gws auth expired) → defer=False (graceful) ─
echo ""
echo "Check 5 — script exits non-zero → defer=False"
HOME_DIR=$(mk_sandbox crashing)
out=$(run_helper "$HOME_DIR")
assert_eq "defer flag" "False" "${out%%|*}"
rm -rf "$HOME_DIR"

echo ""
echo "Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
