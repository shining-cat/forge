#!/usr/bin/env bash
# Tests for forge-context.sh `teammate-notice` subcommand.
# The subcommand is self-gating + HOME-relative, so each case sets HOME to a
# temp dir and toggles TMUX + the settings.json teammateMode value.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC="$SCRIPT_DIR/../forge-context.sh"
PASS=0; FAIL=0

# Build a fresh temp HOME. $1 (optional) = teammateMode value to write into
# settings.json; if empty/omitted, no teammateMode key is written (settings.json
# is still created so we exercise the "key absent" path distinctly from "no file").
mkhome(){ TMP=$(mktemp -d); mkdir -p "$TMP/.claude"; [ -n "${1:-}" ] && printf '{\n  "teammateMode": "%s"\n}\n' "$1" > "$TMP/.claude/settings.json"; }
# Two explicit runners so cases are deterministic even when the suite itself is
# executed from inside a tmux session (ambient $TMUX would otherwise leak into
# the "no tmux" case). run_intmux forces TMUX set; run_notmux forces it unset.
run_intmux(){ TMUX=x HOME="$TMP" "$FC" teammate-notice 2>/dev/null; }
run_notmux(){ env -u TMUX HOME="$TMP" "$FC" teammate-notice 2>/dev/null; }

# 1 gate open: TMUX set, mode auto, no sentinel → prints notice + creates sentinel
mkhome auto; out=$(run_intmux); echo "$out" | grep -q 'split-panes' && [ -f "$TMP/.claude/forge-teammate-notice-shown" ] && { echo "✓ open→notice+sentinel"; PASS=$((PASS+1)); } || { echo "✗ open"; FAIL=$((FAIL+1)); }
# 2 second call now silent (sentinel exists from case 1, same $TMP)
out2=$(run_intmux); [ -z "$out2" ] && { echo "✓ second call silent"; PASS=$((PASS+1)); } || { echo "✗ second"; FAIL=$((FAIL+1)); }
# 3 no tmux → silent
mkhome auto; out=$(run_notmux); [ -z "$out" ] && { echo "✓ no tmux silent"; PASS=$((PASS+1)); } || { echo "✗ tmux"; FAIL=$((FAIL+1)); }
# 4 mode in-process → silent
mkhome in-process; out=$(run_intmux); [ -z "$out" ] && { echo "✓ in-process silent"; PASS=$((PASS+1)); } || { echo "✗ in-process"; FAIL=$((FAIL+1)); }
# 5 mode unset / no settings → silent
mkhome ""; out=$(run_intmux); [ -z "$out" ] && { echo "✓ unset silent"; PASS=$((PASS+1)); } || { echo "✗ unset"; FAIL=$((FAIL+1)); }
# 6 mode tmux → prints notice
mkhome tmux; out=$(run_intmux); echo "$out" | grep -q 'split-panes' && { echo "✓ tmux mode notice"; PASS=$((PASS+1)); } || { echo "✗ tmux mode"; FAIL=$((FAIL+1)); }

echo ""; echo "── Total: $PASS pass, $FAIL fail ──"; exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
