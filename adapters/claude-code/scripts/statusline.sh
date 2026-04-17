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

# Forge status (if active)
FORGE_STATUS=""
if [ -f "$HOME/.claude/forge-active" ]; then
  FORGE_STATUS=$("$HOME/.claude/scripts/forge-context.sh" status 2>/dev/null)
fi

# Create sleek status line with colors
if [ -n "$FORGE_STATUS" ]; then
  printf "\033[33m%s\033[0m | \033[36m⚡ %s\033[0m \033[32m💰 \$%s\033[0m \033[35m⏱️ %ss\033[0m\n" "$FORGE_STATUS" "$MODEL" "$COST_FORMATTED" "$DURATION_SEC"
else
  printf "📁 \033[33m%s 🌿 %s\033[0m | \033[36m⚡ %s\033[0m \033[32m💰 \$%s\033[0m \033[35m⏱️ %ss\033[0m\n" "$DIR_DISPLAY" "$GIT_BRANCH" "$MODEL" "$COST_FORMATTED" "$DURATION_SEC"
fi