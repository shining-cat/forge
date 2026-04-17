#!/bin/bash
set -euo pipefail
# Removes the wellness-coach activity monitor (Tier 2).
# Stops launchd agent, removes binary, sampler, plist, and idle log.

PLIST_NAME="com.claude.wellness-idle-sampler"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
BIN_DIR="$HOME/.claude/bin"
IDLE_LOG="$HOME/.claude/wellness-idle-log.json"

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
rm -f "$BIN_DIR/idle-sampler.py"
echo "  Removed binary and sampler"

# 3. Remove idle log
rm -f "$IDLE_LOG"
rm -f "${IDLE_LOG}.tmp"
echo "  Removed idle log"

# 4. Clean up bin directory if empty
rmdir "$BIN_DIR" 2>/dev/null || true

echo "Activity monitor uninstalled."
echo "Wellness coach will continue in basic mode (Tier 1)."
