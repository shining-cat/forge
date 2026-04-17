#!/bin/bash
# forge-context.sh — Forge session context layer
# Called by Claude Code hooks (PostToolUse, PreToolUse, Stop) and skills.
# Manages breadcrumbs, checkpoint nudges, gate logic, and recovery prompts.

set -euo pipefail

HOME_DIR="$HOME"
MARKER="$HOME_DIR/.claude/forge-active"
VAULT_BASE="{{VAULT_ABSOLUTE}}"  # Patched by install.sh

# ── Read stdin once, store for all subcommands ──────────────────────────
STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON="$(cat)"
fi

# ── Exit silently if Forge is not active ────────────────────────────────
if [ ! -f "$MARKER" ]; then
  exit 0
fi

# ── Determine project name and paths ────────────────────────────────────
PROJECT_NAME="$(head -1 "$MARKER" | tr -d '[:space:]')"

get_vault_dir() {
  case "$1" in
    Forge)
      echo "$VAULT_BASE/_shared"
      ;;
    *)
      # Check for project directly under vault, then scan ENV subdirectories
      if [ -d "$VAULT_BASE/$1" ]; then
        echo "$VAULT_BASE/$1"
      else
        # Scan for {ENV}/{PROJECT} structure
        for env_dir in "$VAULT_BASE"/*/; do
          if [ -d "${env_dir}$1" ]; then
            echo "${env_dir}$1"
            return
          fi
        done
        # Fallback: create directly under vault
        echo "$VAULT_BASE/$1"
      fi
      ;;
  esac
}

get_project_dir() {
  # Read project working directory from forge.conf if available
  local conf="$HOME_DIR/.claude/forge.conf"
  local project_dir=""

  if [ "$1" = "Forge" ]; then
    echo ""
    return
  fi

  # Check forge-active for a stored project path (line 2, if present)
  if [ -f "$MARKER" ] && [ "$(wc -l < "$MARKER" | tr -d ' ')" -ge 2 ]; then
    project_dir="$(sed -n '2p' "$MARKER")"
    if [ -n "$project_dir" ] && [ -d "$project_dir" ]; then
      echo "$project_dir"
      return
    fi
  fi

  echo ""
}

VAULT_DIR="$(get_vault_dir "$PROJECT_NAME")"
PROJECT_DIR="$(get_project_dir "$PROJECT_NAME")"
CHECKPOINT_FILE="$VAULT_DIR/current-checkpoint.md"
BRAINDUMP_FILE="$VAULT_DIR/braindump.md"
BREADCRUMBS_FILE="$VAULT_DIR/breadcrumbs.log"

# ── Helper: age of checkpoint in minutes ────────────────────────────────
get_checkpoint_age_minutes() {
  if [ ! -f "$CHECKPOINT_FILE" ]; then
    echo "9999"
    return
  fi
  local now
  now="$(date +%s)"
  local mtime
  mtime="$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)"
  echo $(( (now - mtime) / 60 ))
}

# ── Helper: age of braindump in minutes ─────────────────────────────────
get_braindump_age_minutes() {
  if [ ! -f "$BRAINDUMP_FILE" ]; then
    echo "9999"
    return
  fi
  local now
  now="$(date +%s)"
  local mtime
  mtime="$(stat -f %m "$BRAINDUMP_FILE" 2>/dev/null || stat -c %Y "$BRAINDUMP_FILE" 2>/dev/null || echo 0)"
  echo $(( (now - mtime) / 60 ))
}

# ── Subcommand: post-tool (breadcrumb logging) ─────────────────────────
do_post_tool() {
  if [ -z "$STDIN_JSON" ]; then
    return
  fi

  # Extract tool name and most relevant input field
  local parsed
  parsed="$(python3 -c "
import json, sys

data = json.loads(sys.argv[1])
tool = data.get('tool_name', 'Unknown')

inp = data.get('tool_input', {})

# Pick the most relevant input field per tool
if tool == 'Bash':
    summary = inp.get('command', '')
elif tool == 'Edit':
    summary = inp.get('file_path', '')
elif tool == 'Write':
    summary = inp.get('file_path', '')
elif tool == 'Read':
    summary = inp.get('file_path', '')
elif tool == 'Glob':
    summary = inp.get('pattern', '')
elif tool == 'Grep':
    summary = inp.get('pattern', '')
elif tool == 'Skill':
    summary = inp.get('skill', '')
else:
    # Fallback: first string value in tool_input
    summary = ''
    for v in inp.values():
        if isinstance(v, str):
            summary = v
            break

print(tool)
print(summary)
" "$STDIN_JSON" 2>/dev/null)" || return 0

  local tool_name input_summary
  tool_name="$(echo "$parsed" | head -1)"
  input_summary="$(echo "$parsed" | tail -1)"

  # Shorten paths: strip home directory prefix
  local tilde="~"
  input_summary="${input_summary//$HOME_DIR/$tilde}"

  # Truncate bash commands at 80 chars
  if [ "$tool_name" = "Bash" ] && [ "${#input_summary}" -gt 80 ]; then
    input_summary="${input_summary:0:80}…"
  fi

  # Append breadcrumb line
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  mkdir -p "$(dirname "$BREADCRUMBS_FILE")"
  echo "$timestamp | $tool_name | $input_summary" >> "$BREADCRUMBS_FILE"

  # ── Brain dump prompt (if >10min since last entry) ──────────────────
  local dump_age checkpoint_age output
  dump_age="$(get_braindump_age_minutes)"
  checkpoint_age="$(get_checkpoint_age_minutes)"
  output=""

  if [ "$dump_age" -ge 10 ]; then
    output="{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"[Keeper] Brain dump due (${dump_age}min since last). Append 2-3 lines to braindump.md: what you're working on, what you just figured out, what's next. File: $BRAINDUMP_FILE\"}}"
  fi

  # ── Push/PR nudge (checkpoint reminder on push or PR creation) ──────
  local command
  command="$(echo "$STDIN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)" || command=""
  case "$command" in
    *"git push"*|*"git -C"*push*|*"gh pr create"*)
      if [ "$checkpoint_age" -ge 2 ]; then
        output="{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"[Keeper] Push/PR detected on project $PROJECT_NAME. Checkpoint is ${checkpoint_age} minutes old. Write a checkpoint now — run /forge-checkpoint.\"}}"
      fi
      ;;
  esac

  # Output JSON if any action needed
  if [ -n "$output" ]; then
    echo "$output"
  fi
}

# ── Subcommand: gate (conditional commit gate) ────────────────────────
do_gate() {
  if [ -z "$STDIN_JSON" ]; then
    exit 0
  fi

  # Verify this is actually a git commit command
  local command
  command="$(echo "$STDIN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)" || command=""
  case "$command" in
    *"git commit"*|*"git -C"*commit*)
      ;;
    *)
      exit 0
      ;;
  esac

  local age
  age="$(get_checkpoint_age_minutes)"

  if [ "$age" -gt 15 ]; then
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[Keeper] Checkpoint is ${age}min stale (project: $PROJECT_NAME). Write a checkpoint before committing — run /forge-checkpoint."}}
EOF
    exit 0
  fi

  exit 0
}

# ── Subcommand: stop (staleness check on session end) ──────────────────
do_stop() {
  local age
  age="$(get_checkpoint_age_minutes)"

  if [ "$age" -ge 60 ]; then
    cat <<EOF
{"decision":"block","reason":"[Keeper] Checkpoint is ${age} minutes old (project: $PROJECT_NAME). Write a checkpoint now before continuing — run /forge-checkpoint."}
EOF
    exit 2
  elif [ "$age" -ge 30 ]; then
    cat <<EOF
{"systemMessage":"[Keeper] Checkpoint is ${age} minutes old (project: $PROJECT_NAME). Consider updating it soon."}
EOF
  fi
  exit 0
}

# ── Subcommand: recover (session start reconstruction) ─────────────────
do_recover() {
  echo "=== FORGE RECOVERY — $PROJECT_NAME ==="

  # Checkpoint baseline
  if [ -f "$CHECKPOINT_FILE" ]; then
    local cp_mod now cp_age_min cp_date
    cp_mod="$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    cp_age_min=$(( (now - cp_mod) / 60 ))
    cp_date="$(date -r "$cp_mod" "+%Y-%m-%dT%H:%M" 2>/dev/null || date -d "@$cp_mod" "+%Y-%m-%dT%H:%M" 2>/dev/null)"
    echo "Checkpoint: $cp_date (${cp_age_min} minutes ago)"
  else
    echo "Checkpoint: NONE"
    local cp_mod="0"
  fi

  # Git state
  if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
    local branch git_status
    branch="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null)"
    git_status="$(git -C "$PROJECT_DIR" status --short 2>/dev/null)"
    echo "Branch: ${branch:-detached}"
    if [ -z "$git_status" ]; then
      echo "Git state: clean"
    else
      echo "Git state: uncommitted changes"
      echo "$git_status" | head -10 | sed 's/^/  /'
    fi

    # Commits since checkpoint
    if [ -f "$CHECKPOINT_FILE" ]; then
      echo ""
      echo "--- Commits since checkpoint ---"
      local since_date commits
      since_date="$(date -r "$cp_mod" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -d "@$cp_mod" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null)"
      commits="$(git -C "$PROJECT_DIR" log --oneline --since="$since_date" 2>/dev/null)"
      if [ -n "$commits" ]; then
        echo "$commits"
      else
        echo "(none)"
      fi
    fi
  fi

  # Brain dump
  if [ -f "$BRAINDUMP_FILE" ] && [ -s "$BRAINDUMP_FILE" ]; then
    echo ""
    echo "--- Brain dump (unfolded) ---"
    cat "$BRAINDUMP_FILE"
  fi

  # Breadcrumb summary
  if [ -f "$BREADCRUMBS_FILE" ] && [ -s "$BREADCRUMBS_FILE" ]; then
    echo ""
    echo "--- Breadcrumb summary ---"
    local total tool_counts files
    total="$(wc -l < "$BREADCRUMBS_FILE" | tr -d ' ')"
    tool_counts="$(awk -F' \\| ' '{print $2}' "$BREADCRUMBS_FILE" | sort | uniq -c | sort -rn | head -5 | awk '{printf "%s %s, ", $1, $2}' | sed 's/, $//')"
    echo "$total tool calls: $tool_counts"

    files="$(awk -F' \\| ' '$2 ~ /Edit|Write/ {print $3}' "$BREADCRUMBS_FILE" | sort -u | head -10)"
    if [ -n "$files" ]; then
      echo "Files modified:"
      echo "$files" | sed 's/^/  /'
    fi
  fi

  # PRs (if project has a git remote)
  if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
    local remote
    remote="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null)"
    if [ -n "$remote" ]; then
      echo ""
      echo "--- PRs ---"
      local repo pr_json
      if echo "$remote" | grep -q "github.schibsted.io"; then
        repo="$(echo "$remote" | sed 's|.*github.schibsted.io[:/]||;s|\.git$||')"
        pr_json="$(GH_HOST=github.schibsted.io gh pr list --author @me --repo "$repo" --state open --limit 5 --json number,title,reviewDecision 2>/dev/null)"
      else
        repo="$(echo "$remote" | sed 's|.*github.com[:/]||;s|\.git$||')"
        pr_json="$(gh pr list --author @me --repo "$repo" --state open --limit 5 --json number,title,reviewDecision 2>/dev/null)"
      fi
      if [ -n "$pr_json" ] && [ "$pr_json" != "[]" ]; then
        echo "$pr_json" | python3 -c "
import sys,json
for pr in json.load(sys.stdin):
    status = pr.get('reviewDecision','PENDING').lower().replace('_',' ')
    print(f'#{pr[\"number\"]} {pr[\"title\"]}: {status}')
" 2>/dev/null
      else
        echo "(no open PRs)"
      fi
    fi
  fi

  echo "========================"

  # Truncate breadcrumbs (fresh session)
  if [ -f "$BREADCRUMBS_FILE" ]; then
    > "$BREADCRUMBS_FILE"
  fi
}

# ── Subcommand: status (statusline integration) ───────────────────────
do_status() {
  local age
  age="$(get_checkpoint_age_minutes)"

  local branch=""
  if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
    branch="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null)"
  fi

  local indicator
  if [ "$age" -le 15 ]; then
    indicator="✓ ${age}m"
  elif [ "$age" -le 30 ]; then
    indicator="⚠ ${age}m"
  else
    indicator="🔴 ${age}m"
  fi

  echo "⚒ $PROJECT_NAME | 🌿 ${branch:-n/a} | $indicator"
}

# ── Dispatch ────────────────────────────────────────────────────────────
SUBCMD="${1:-}"

case "$SUBCMD" in
  post-tool)  do_post_tool ;;
  gate)       do_gate ;;
  stop)       do_stop ;;
  recover)    do_recover ;;
  status)     do_status ;;
  *)
    echo "Usage: forge-context.sh {post-tool|gate|stop|recover|status}" >&2
    exit 1
    ;;
esac
