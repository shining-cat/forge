#!/usr/bin/env bash
# forge-exit-guard.sh — UserPromptSubmit hook (L1 deny on bare exit/quit)
#
# If the user types bare `exit` or `quit` (exact, case-insensitive)
# while Forge is active in the current window, emits a block decision
# with Petra-voiced prose pointing to /forge-exit. Otherwise lets the
# prompt through unchanged.
#
# Behavior:
#   1. Source forge-context.sh helpers (single source of truth).
#   2. Read prompt from stdin JSON. If not a close-out verb → allow.
#   3. Gate on session_owns_forge — only intercept in the window that
#      ran /forge. Sibling Claude Code windows that didn't enter Forge
#      shouldn't be told to "use /forge-exit" — they have nothing to
#      wrap up.
#   4. If owner + close-out verb: emit {"decision":"block","reason":...}
#      via stdout JSON. Reason routes user to /forge-exit, mentions
#      Ctrl-D as the escape (caught by L2 forge-session-end.sh).
#
# Always exits 0 — block decisions go via stdout JSON, not exit code.
#
# CONTINGENT: Whether typed `exit`/`quit` reaches UserPromptSubmit at
# all is undocumented in Claude Code (as of 2026-05-06). If it
# doesn't, this script is silently dormant — no harm. L2
# (forge-session-end.sh) still catches the cleanup.

set -euo pipefail

# Read the prompt context JSON from stdin first; helper expects
# STDIN_JSON to be set for the session_id fallback path.
INPUT="$(cat 2>/dev/null || echo '{}')"
export STDIN_JSON="$INPUT"

# Extract prompt early — if it's not a close-out verb, return fast
# without sourcing helpers (cheap guard for the common case where
# this hook fires on every keypress).
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || echo "")"
NORMALIZED="$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

case "$NORMALIZED" in
  exit|quit) ;;
  *) exit 0 ;;  # not a close-out verb — let the prompt through
esac

# It IS a close-out verb. Source the helpers to gate on ownership.
# shellcheck disable=SC1091
source "$HOME/.claude/scripts/forge-context.sh"

# Session-isolation gate: only intercept in the window that owns the
# marker. Sibling windows pass the prompt through; if their user means
# to leave THIS terminal, they don't have a Forge wrap-up to skip.
session_owns_forge || exit 0

# Forge active + this is the owner window + user typed bare exit/quit.
# Emit the deny.
REASON="Petra: Heading out, or hit the wrong key? Type /forge-exit if we're done — I'll bank everything properly. Stay if not. Close the window if you really must bail — cleanup runs either way via the SessionEnd hook."

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'

exit 0
