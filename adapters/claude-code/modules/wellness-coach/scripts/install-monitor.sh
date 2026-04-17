#!/bin/bash
set -euo pipefail
# Installs the wellness-coach activity monitor (Tier 2).
# Compiles screen_state binary, installs idle sampler, sets up launchd agent.

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.claude/bin"
PLIST_NAME="com.claude.wellness-idle-sampler"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
SAMPLER_SRC="$PLUGIN_DIR/scripts/idle-sampler.py"
BINARY_SRC="$PLUGIN_DIR/src/screen_state.c"

echo "Installing wellness-coach activity monitor..."

# 1. Create bin directory
mkdir -p "$BIN_DIR"

# 2. Compile screen_state binary
echo "Compiling screen state checker..."
if ! command -v cc &>/dev/null; then
    echo "Error: C compiler not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

cc -O2 -framework CoreGraphics -framework CoreFoundation \
    "$BINARY_SRC" -o "$BIN_DIR/screen_state"

# 3. Copy sampler script
cp "$SAMPLER_SRC" "$BIN_DIR/idle-sampler.py"
chmod +x "$BIN_DIR/idle-sampler.py"

# 4. Find python3 path (use absolute path in plist)
PYTHON3_PATH="$(command -v python3)"
if [ -z "$PYTHON3_PATH" ]; then
    echo "Error: python3 not found."
    exit 1
fi

# 5. Create launchd plist
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON3_PATH}</string>
        <string>${BIN_DIR}/idle-sampler.py</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>${HOME}/.claude/wellness-idle-sampler.log</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF

# 6. Load the agent
# Unload first if already running (upgrade case)
launchctl bootout "gui/$(id -u)/${PLIST_NAME}" 2>/dev/null || true
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"; then
    echo "Error: Failed to load LaunchAgent. Cleaning up..."
    rm -f "$BIN_DIR/screen_state"
    rm -f "$BIN_DIR/idle-sampler.py"
    rm -f "$PLIST_PATH"
    rmdir "$BIN_DIR" 2>/dev/null || true
    exit 1
fi

echo "Activity monitor installed successfully."
echo "  Binary: $BIN_DIR/screen_state"
echo "  Sampler: $BIN_DIR/idle-sampler.py"
echo "  LaunchAgent: $PLIST_PATH"
echo ""
echo "To uninstall: run $(dirname "$0")/uninstall-monitor.sh"
