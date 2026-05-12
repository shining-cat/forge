#!/bin/bash
# Read JSON input once
input=$(cat)

# Helper functions for common extractions
get_model_name() { echo "$input" | jq -r '.model.display_name'; }
get_current_dir() { echo "$input" | jq -r '.workspace.current_dir'; }
get_project_dir() { echo "$input" | jq -r '.workspace.project_dir'; }
get_version() { echo "$input" | jq -r '.version'; }
get_cost() { echo "$input" | jq -r '.cost.total_cost_usd'; }
get_duration() { echo "$input" | jq -r '.cost.total_duration_ms'; }
get_lines_added() { echo "$input" | jq -r '.cost.total_lines_added'; }
get_lines_removed() { echo "$input" | jq -r '.cost.total_lines_removed'; }

# Extract values
MODEL=$(get_model_name)
CURRENT_DIR=$(get_current_dir)
PROJECT_DIR=$(get_project_dir)
COST=$(get_cost)
DURATION=$(get_duration)
GIT_BRANCH=""

if git rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git branch --show-current 2>/dev/null)
    if [ -n "$BRANCH" ]; then
        GIT_BRANCH="$BRANCH"
    fi
fi

# Format directory display
if [ "$CURRENT_DIR" = "$PROJECT_DIR" ]; then
    DIR_DISPLAY="${CURRENT_DIR##*/}"
else
    PROJECT_NAME="${PROJECT_DIR##*/}"
    CURRENT_NAME="${CURRENT_DIR##*/}"
    DIR_DISPLAY="$PROJECT_NAME/$CURRENT_NAME"
fi

# Format cost (max 1 decimal place)
COST_FORMATTED=$(printf "%.1f" "$COST")

# Format duration (convert ms to seconds, no decimal places)
DURATION_SEC=$(echo "scale=0; $DURATION / 1000" | bc 2>/dev/null || echo "0")

# Forge status (if active) — resolve marker via VAULT_PATH from forge.conf
# Soft-fail: missing forge.conf or VAULT_PATH renders no chip (statusline must not break).
FORGE_STATUS=""
FORGE_CONF="$HOME/.claude/forge.conf"
MARKER=""
if [ -f "$FORGE_CONF" ]; then
  VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
  [ -n "$VAULT_PATH" ] && MARKER="$VAULT_PATH/_shared/forge-active"
fi

if [ -n "$MARKER" ] && [ -f "$MARKER" ]; then
  marker_value=$(head -1 "$MARKER" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -z "$marker_value" ]; then
    FORGE_STATUS="[Forge | -]"
  elif [ "$marker_value" = "__pending__" ]; then
    FORGE_STATUS="[Forge | choosing…]"
  else
    # Pipe $input through so forge-context.sh can read .session_id from stdin —
    # CLAUDE_CODE_SESSION_ID is NOT inherited by the statusline subprocess, so
    # without this pipe session_owns_forge falls through both signals and every
    # window renders as ⚠ "(other window)". $input is the same JSON the
    # statusline already consumed at line 3.
    FORGE_STATUS=$(echo "$input" | "$HOME/.claude/scripts/forge-context.sh" status 2>/dev/null)
  fi
fi

# Wellness chips — soft-fails to empty if wellness-coach not installed or vault unreachable
WELLNESS_STATUS=""
WELLNESS_SCRIPT="$HOME/.claude/skills/wellness-coach/scripts/wellness-status.sh"
[ -x "$WELLNESS_SCRIPT" ] && WELLNESS_STATUS=$("$WELLNESS_SCRIPT" 2>/dev/null)

# Create sleek status line with colors
if [ -n "$FORGE_STATUS" ]; then
  printf "\033[33m%s\033[0m | \033[36m⚡ %s\033[0m \033[32m💰 \$%s\033[0m \033[35m⏱️ %ss\033[0m | %s\n" "$FORGE_STATUS" "$MODEL" "$COST_FORMATTED" "$DURATION_SEC" "$WELLNESS_STATUS"
else
  printf "📁 \033[33m%s 🌿 %s\033[0m | \033[36m⚡ %s\033[0m \033[32m💰 \$%s\033[0m \033[35m⏱️ %ss\033[0m | %s\n" "$DIR_DISPLAY" "$GIT_BRANCH" "$MODEL" "$COST_FORMATTED" "$DURATION_SEC" "$WELLNESS_STATUS"
fi