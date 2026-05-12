#!/usr/bin/env bash
# forge-session-end.sh — SessionEnd hook (L2 cleanup safety net)
#
# Always-on cleanup that runs whenever a Claude Code session terminates
# (any SessionEnd matcher: clear, resume, logout, prompt_input_exit,
# bypass_permissions_disabled, other). Catches typed `exit`/`quit`,
# Ctrl-D, accidental window close, OS shutdown — anything that ends the
# session without going through /forge-exit.
#
# Behavior:
#   1. Source forge-context.sh helpers (single source of truth for
#      marker reading, ownership gating, vault-dir resolution).
#   2. Gate on session_owns_forge — only the window that ran /forge
#      cleans up. Sibling Claude Code windows that didn't enter Forge
#      are no-ops here, so they don't accidentally clear the owner's
#      active marker.
#   3. If owner: append a timestamp line to the active project's
#      checkpoint, then clear the forge-active marker.
#
# Always exits 0 — SessionEnd is observe-only per Claude Code hook
# spec; can't block or fail-loud.
#
# Empirical risk (2026-05-12, when shipped): Claude Code's SessionEnd
# stdin payload may or may not include `session_id`. If env var
# CLAUDE_CODE_SESSION_ID isn't inherited AND stdin lacks session_id,
# session_owns_forge returns false → cleanup never fires (silent).
# Verify post-restart: terminate via Ctrl-D, check next session that
# marker was cleared + checkpoint has the new line. If not, gating
# signal is unavailable here and needs a different mechanism.

set -euo pipefail

# Read SessionEnd context JSON from stdin first; helper expects
# STDIN_JSON to be set for the session_id fallback path.
INPUT="$(cat 2>/dev/null || echo '{}')"
export STDIN_JSON="$INPUT"

# Source the helpers. This sets HOME_DIR/FORGE_CONF/VAULT_PATH/MARKER
# and defines extract_marker_project, session_owns_forge, get_vault_dir.
# shellcheck disable=SC1091
source "$HOME/.claude/scripts/forge-context.sh"

# Session-isolation gate: only fire in the window that owns the marker.
# Legacy plain-string markers preserve old global behavior (helper
# returns true for them, so cleanup still runs — same back-compat as
# the post-tool/gate/stop hooks).
session_owns_forge || exit 0

# Extract project from marker (JSON-aware via the shared helper).
PROJECT="$(extract_marker_project)"
[ -n "$PROJECT" ] || exit 0  # marker empty / __pending__ → no-op

# Resolve project → vault dir (case-insensitive across all env dirs).
VAULT_DIR="$(get_vault_dir "$PROJECT" 2>/dev/null)"
[ -n "$VAULT_DIR" ] || exit 0  # unknown project → can't write checkpoint

# Extract the SessionEnd matcher for the timestamp annotation.
MATCHER="$(printf '%s' "$INPUT" | jq -r '.matcher // "unknown"' 2>/dev/null || echo "unknown")"

# Append timestamp line to checkpoint (if the file exists).
CHECKPOINT="$VAULT_DIR/current-checkpoint.md"
if [ -f "$CHECKPOINT" ]; then
  printf '\n_Session ended at %s via SessionEnd matcher=%s_\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$MATCHER" >> "$CHECKPOINT"
fi

# Clear the marker (write empty — same convention as /forge-exit).
: > "$MARKER"

exit 0
