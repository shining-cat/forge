#!/bin/bash
# Sends a macOS notification
# Usage: notify.sh "Title" "Body"

TITLE="${1:-Wellness Coach}"
BODY="${2:-Time for a break!}"

osascript - "$TITLE" "$BODY" <<'EOF' 2>/dev/null
on run argv
    display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"
end run
EOF
