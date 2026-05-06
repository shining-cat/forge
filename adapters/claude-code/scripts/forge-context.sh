#!/bin/bash
# forge-context.sh — Forge session context layer
# Called by Claude Code hooks (PostToolUse, PreToolUse, Stop) and skills.
# Manages breadcrumbs, checkpoint nudges, gate logic, and recovery prompts.

set -euo pipefail

HOME_DIR="$HOME"

# Resolve marker path from forge.conf VAULT_PATH
FORGE_CONF="$HOME_DIR/.claude/forge.conf"
if [ ! -f "$FORGE_CONF" ]; then
  echo "[forge-context] ERROR: forge.conf not found at $FORGE_CONF" >&2
  exit 1
fi
VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
if [ -z "$VAULT_PATH" ]; then
  echo "[forge-context] ERROR: VAULT_PATH not set in $FORGE_CONF" >&2
  exit 1
fi
MARKER="$VAULT_PATH/_shared/forge-active"

# Reconcile marker against most-recent-checkpoint frontmatter.
# Emits a one-line warning to stderr if marker disagrees with truth.
# Skips silently for missing/empty/__pending__ markers.
reconcile_marker() {
  if [ ! -f "$MARKER" ]; then
    return 0
  fi
  local marker_value
  marker_value=$(head -1 "$MARKER" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -z "$marker_value" ] || [ "$marker_value" = "__pending__" ]; then
    return 0
  fi
  # Most recent checkpoint by mtime (proxy for `date:` frontmatter — good enough)
  local newest_checkpoint
  newest_checkpoint=$(find "$VAULT_PATH" -path '*/current-checkpoint.md' -print0 2>/dev/null | \
    xargs -0 ls -t 2>/dev/null | head -1)
  if [ -z "$newest_checkpoint" ]; then
    return 0
  fi
  local checkpoint_project
  checkpoint_project=$(grep '^project:' "$newest_checkpoint" 2>/dev/null | head -1 | sed 's/project:[[:space:]]*//' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  local checkpoint_date
  checkpoint_date=$(grep '^date:' "$newest_checkpoint" 2>/dev/null | head -1 | sed 's/date:[[:space:]]*//' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ -n "$checkpoint_project" ] && [ "$checkpoint_project" != "$marker_value" ]; then
    echo "[Keeper] Marker mismatch: forge-active says \"$marker_value\" but most recent checkpoint is for \"$checkpoint_project\" (${checkpoint_date:-unknown date}). If this is intentional cross-env work, ignore. Otherwise: switch projects or update the marker." >&2
  fi
}

# ── Sourceable boundary ─────────────────────────────────────────────────
# Everything below runs only when this file is executed as a script.
# When sourced (e.g., from forge-compaction.sh to reuse `reconcile_marker`),
# the resolver above and the function definition stay in scope, but no
# stdin is consumed and no subcommand dispatch runs.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

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
PROJECT_NAME="$(head -1 "$MARKER" 2>/dev/null | tr -d '[:space:]')"

# Empty marker = Forge deactivated (exit wrote empty file)
if [ -z "$PROJECT_NAME" ]; then
  exit 0
fi

# __pending__ = Forge is launching, no project chosen yet (set by skills/forge step 1a).
# Treat the same as empty so non-reconcile subcommands don't fall through to
# get_vault_dir "__pending__" and create stray Vault/PERSO/__pending__/ dirs.
if [ "$PROJECT_NAME" = "__pending__" ]; then
  exit 0
fi

# Resolve vault directory for a project by scanning $VAULT_PATH/{env}/{project}/
# case-insensitively. Skips underscore-prefixed env dirs (_shared, _templates).
# Emits stderr warning + empty stdout if no match.
get_vault_dir() {
  local project="$1"
  local target_lower
  target_lower="$(echo "$project" | tr '[:upper:]' '[:lower:]')"
  local env_dir env_name proj_dir proj_name
  for env_dir in "$VAULT_PATH"/*/; do
    [ -d "$env_dir" ] || continue
    env_name="$(basename "$env_dir")"
    case "$env_name" in _*) continue ;; esac
    for proj_dir in "$env_dir"*/; do
      [ -d "$proj_dir" ] || continue
      proj_name="$(basename "$proj_dir")"
      if [ "$(echo "$proj_name" | tr '[:upper:]' '[:lower:]')" = "$target_lower" ]; then
        echo "${proj_dir%/}"
        return 0
      fi
    done
  done
  echo "[forge-context] no vault dir found for project '$project' under $VAULT_PATH" >&2
  return 1
}

# Resolve project repo directory by scanning $HOME_DIR/__DEV/{env}/{project}/
# case-insensitively. Skips Vault* and underscore-prefixed dirs at the env level.
# Emits stderr warning + empty stdout if no match.
get_project_dir() {
  local project="$1"
  local target_lower
  target_lower="$(echo "$project" | tr '[:upper:]' '[:lower:]')"
  local env_dir env_name proj_dir proj_name
  for env_dir in "$HOME_DIR/__DEV"/*/; do
    [ -d "$env_dir" ] || continue
    env_name="$(basename "$env_dir")"
    case "$env_name" in _*|Vault*) continue ;; esac
    for proj_dir in "$env_dir"*/; do
      [ -d "$proj_dir" ] || continue
      proj_name="$(basename "$proj_dir")"
      if [ "$(echo "$proj_name" | tr '[:upper:]' '[:lower:]')" = "$target_lower" ]; then
        echo "${proj_dir%/}"
        return 0
      fi
    done
  done
  echo "[forge-context] no project repo found for '$project' under $HOME_DIR/__DEV/" >&2
  return 1
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
  # Stacked throttle: subagent guard + just-dumped mtime + per-response cooldown.
  # Fixes per-tool-call refire pattern (see vault task keeper-braindump-hook-suppress-in-subagents).
  local dump_age checkpoint_age output session_id agent_id now braindump_mtime cooldown_marker cooldown_age
  dump_age="$(get_braindump_age_minutes)"
  checkpoint_age="$(get_checkpoint_age_minutes)"
  output=""

  # Defensive subagent guard — Claude Code issue #34692 says PostToolUse
  # may not fire in subagents, but observed counter-evidence; harmless either way.
  agent_id="$(echo "$STDIN_JSON" | jq -r '.agent_id // empty' 2>/dev/null)"
  if [ -n "$agent_id" ]; then
    return 0
  fi

  # Just-dumped check — if braindump.md was touched within 60s, suppress.
  now="$(date +%s)"
  if [ -f "$BRAINDUMP_FILE" ]; then
    braindump_mtime="$(stat -f %m "$BRAINDUMP_FILE" 2>/dev/null || stat -c %Y "$BRAINDUMP_FILE" 2>/dev/null || echo 0)"
    if [ $((now - braindump_mtime)) -lt 60 ]; then
      return 0
    fi
  fi

  # Per-response cooldown — if marker exists and is fresh, suppress.
  session_id="$(echo "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)"
  if [ -n "$session_id" ]; then
    cooldown_marker="/tmp/forge-braindump-cooldown-${session_id}"
    if [ -f "$cooldown_marker" ]; then
      cooldown_age="$(stat -f %m "$cooldown_marker" 2>/dev/null || stat -c %Y "$cooldown_marker" 2>/dev/null || echo 0)"
      if [ $((now - cooldown_age)) -lt 60 ]; then
        return 0
      fi
    fi
  fi

  if [ "$dump_age" -ge 10 ]; then
    # Touch the cooldown marker before emitting (suppresses next tool call within 60s).
    [ -n "$session_id" ] && touch "/tmp/forge-braindump-cooldown-${session_id}" 2>/dev/null
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
        pr_json="$(GH_HOST=github.com gh pr list --author @me --repo "$repo" --state open --limit 5 --json number,title,reviewDecision 2>/dev/null)"
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

  # Vault state — surfaces drift in the vault repo itself (not the project repo).
  # Loss of laptop = loss of all decisions/checkpoints/plans if the vault never gets pushed.
  if [ -d "$VAULT_PATH/.git" ]; then
    echo ""
    echo "--- Vault state ---"
    local vault_dirty vault_ahead vault_behind vault_untracked_dirs
    vault_dirty="$(git -C "$VAULT_PATH" status --short 2>/dev/null | wc -l | tr -d ' ')"
    vault_ahead="$(git -C "$VAULT_PATH" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    vault_behind="$(git -C "$VAULT_PATH" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
    vault_untracked_dirs="$(git -C "$VAULT_PATH" status --short 2>/dev/null | awk '/^\?\?/ {print $2}' | awk -F/ '{print $1}' | sort -u | wc -l | tr -d ' ')"

    if [ "$vault_dirty" -eq 0 ] && [ "$vault_ahead" -eq 0 ] && [ "$vault_behind" -eq 0 ]; then
      echo "Clean, in sync with origin."
    else
      [ "$vault_dirty" -gt 0 ] && echo "Dirty files: $vault_dirty"
      [ "$vault_untracked_dirs" -gt 0 ] && echo "Untracked top-level dirs: $vault_untracked_dirs"
      [ "$vault_ahead" -gt 0 ] && echo "Unpushed commits: $vault_ahead"
      [ "$vault_behind" -gt 0 ] && echo "Behind origin: $vault_behind"
    fi
  elif ! grep -q '^VAULT_GIT_DECLINED=true' "$HOME/.claude/forge.conf" 2>/dev/null; then
    echo ""
    echo "--- Vault state ---"
    echo "Not under version control. Decisions, checkpoints, plans live only on this disk."
    echo "Run \`git -C $VAULT_PATH init\` to enable history + recovery."
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

  # Checkpoint freshness chip: 💾 always (semantic = "save state"), color = urgency
  # green ≤15min, yellow ≤30min, red >30min. "ago" suffix anchors elapsed-time meaning.
  local color
  if [ "$age" -le 15 ]; then
    color='\033[32m'  # green
  elif [ "$age" -le 30 ]; then
    color='\033[33m'  # yellow
  else
    color='\033[31m'  # red
  fi
  local indicator
  indicator=$(printf "${color}💾 %sm ago\033[0m" "$age")

  echo "⚒ $PROJECT_NAME | 🌿 ${branch:-n/a} | $indicator"
}

# ── Dispatch ────────────────────────────────────────────────────────────
SUBCMD="${1:-}"

case "$SUBCMD" in
  post-tool)         do_post_tool ;;
  gate)              do_gate ;;
  stop)              do_stop ;;
  recover)           do_recover ;;
  reconcile-marker)  reconcile_marker ;;
  status)            do_status ;;
  *)
    echo "Usage: forge-context.sh {post-tool|gate|stop|recover|reconcile-marker|status}" >&2
    exit 1
    ;;
esac
