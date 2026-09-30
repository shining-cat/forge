#!/bin/bash
set -euo pipefail
# Removes the wellness-coach activity monitor (Tier 2).
# Stops launchd agent, removes binary, sampler, plist, and idle log.

PLIST_NAME="com.claude.wellness-idle-sampler"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
BIN_DIR="$HOME/.claude/bin"
LOCATION_SCRIPT="$(cd "$(dirname "$0")/../hooks" && pwd)/wellness_location.py"
IDLE_LOG=""
LOG_LOOKUP_FAILED=0
IDLE_LOG=$(python3 "$LOCATION_SCRIPT" file wellness-idle-log.json) || LOG_LOOKUP_FAILED=1

echo "Uninstalling wellness-coach activity monitor..."

# 1. Stop and unload launchd agent
if [ -f "$PLIST_PATH" ]; then
    if ! launchctl bootout "gui/$(id -u)/${PLIST_NAME}" 2>/dev/null; then
        echo "  Warning: could not stop LaunchAgent (may not be running)"
    fi
    rm -f "$PLIST_PATH"
    echo "  Removed LaunchAgent"
fi

# 2. Remove binary and sampler
rm -f "$BIN_DIR/screen_state"
rm -f "$BIN_DIR/idle-sampler.py" "$BIN_DIR/wellness_location.py"
echo "  Removed binary and sampler"

# 3. Remove idle log
if [ "$LOG_LOOKUP_FAILED" -eq 0 ] &&
   python3 "$LOCATION_SCRIPT" consented >/dev/null 2>&1; then
    rm -f "$IDLE_LOG" "${IDLE_LOG}.tmp"
fi
if [ "$LOG_LOOKUP_FAILED" -eq 0 ]; then
    echo "  Removed idle log (if present)"
else
    echo "  Could not resolve idle log; repair the vault locator before removing it." >&2
fi

# 4. Clean up bin directory if empty
rmdir "$BIN_DIR" 2>/dev/null || true

echo "Activity monitor uninstalled."
if [ "$LOG_LOOKUP_FAILED" -ne 0 ]; then
    exit 1
fi
echo "Wellness coach will continue in basic mode (Tier 1)."
