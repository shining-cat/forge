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

# Vault drift thresholds — recover() warns when any one is exceeded
VAULT_DRIFT_COMMITS_AHEAD=5
VAULT_DRIFT_DIRTY_FILES=10
VAULT_DRIFT_DAYS_SINCE=7

# Read the marker file and return the project name.
# Empty stdout if marker is missing/empty/__pending__.
# Handles both JSON markers (new, session-isolated) and plain-string markers (legacy).
extract_marker_project() {
  [ ! -f "$MARKER" ] && return 0
  local marker_text proj
  marker_text=$(cat "$MARKER" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$marker_text" in
    ""|"__pending__") return 0 ;;
  esac
  # Try parse as JSON first
  proj=$(echo "$marker_text" | jq -r '.project // empty' 2>/dev/null)
  if [ -n "$proj" ]; then
    echo "$proj"
  else
    # Legacy plain-string marker — first line is the project name
    echo "$marker_text" | head -1
  fi
}

# Returns 0 (true) if the current Claude Code session owns the active Forge marker,
# 1 (false) if another session owns it OR no Forge is active.
# Used to gate hooks (post-tool, gate, stop) so they only fire in the window that ran /forge.
# Legacy plain-string markers (from before JSON migration) → return 0 to preserve old
# behavior — sibling windows will continue to leak hooks until /forge is re-invoked.
session_owns_forge() {
  [ ! -f "$MARKER" ] && return 1
  local marker_text marker_session current_session
  marker_text=$(cat "$MARKER" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$marker_text" in
    ""|"__pending__") return 1 ;;
  esac
  marker_session=$(echo "$marker_text" | jq -r '.session_id // empty' 2>/dev/null)
  # Legacy plain-string marker → preserve old global behavior
  [ -z "$marker_session" ] && return 0
  # JSON marker — compare session IDs
  current_session="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -z "$current_session" ] && [ -n "${STDIN_JSON:-}" ]; then
    current_session=$(echo "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)
  fi
  [ "$marker_session" = "$current_session" ]
}

# Reconcile marker against most-recent-checkpoint frontmatter.
# Emits a one-line warning to stderr if marker disagrees with truth.
# Skips silently for missing/empty/__pending__ markers.
reconcile_marker() {
  local marker_value
  marker_value=$(extract_marker_project)
  if [ -z "$marker_value" ]; then
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

# Returns 0 if Pip (wellness coach) is on strike (tool use blocked), 1 otherwise.
# Used by do_stop and do_post_tool to suppress nags during a strike — without
# this short-circuit, Keeper's Stop hook fires on every response and the user
# cannot satisfy it (writing a checkpoint requires tool calls Pip blocks),
# producing a hook-deadlock loop. See friction log 2026-05-07 — "Hook
# coordination deadlock loop". Fail-open: if wellness file is missing or
# unreadable, treat as not-on-strike (wellness-disabled installs unaffected).
is_pip_on_strike() {
  local prefs="${VAULT_PATH}/_shared/wellness-preferences.json"
  [ -f "$prefs" ] || return 1
  local strike
  strike="$(jq -r '.strike_active // false' "$prefs" 2>/dev/null)"
  [ "$strike" = "true" ]
}

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

# ── Sourceable boundary ─────────────────────────────────────────────────
# Everything below runs only when this file is executed as a script.
# When sourced (e.g., from forge-compaction.sh or forge-session-end.sh to
# reuse the helpers above), VAULT_PATH/MARKER resolution + all helper
# definitions (extract_marker_project,
# session_owns_forge, reconcile_marker, is_pip_on_strike, get_vault_dir,
# get_project_dir) stay in scope, but no stdin is consumed and no
# subcommand dispatch runs.
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
# extract_marker_project handles JSON markers (new), legacy plain-string markers,
# and the special __pending__ + empty/missing values (returns empty stdout).
PROJECT_NAME="$(extract_marker_project)"

# Empty result covers: marker missing, empty marker (deactivated by /forge-exit),
# __pending__ (Forge launching, no project chosen yet — exit so non-reconcile
# subcommands don't fall through to get_vault_dir "__pending__" and create stray
# Vault/PERSO/__pending__/ dirs).
if [ -z "$PROJECT_NAME" ]; then
  exit 0
fi

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
  # Session-isolation gate: only fire in the window that owns Forge.
  # Sibling Claude Code windows reading the same marker file exit silently here
  # so they don't leak braindump prompts / push nudges. Legacy plain-string
  # markers preserve old global behavior (helper returns true).
  session_owns_forge || exit 0

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

  # Pip on strike — breadcrumb still recorded above, but suppress all nags
  # below (brain-dump, push/PR nudge). User can't act on them during a strike,
  # and Keeper's Stop hook would loop on the resulting empty responses.
  if is_pip_on_strike; then
    return 0
  fi

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
  # Session-isolation gate: don't block commits in sibling Claude Code windows
  # that didn't run /forge themselves. See session_owns_forge().
  session_owns_forge || exit 0

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
  # Session-isolation gate: don't fire checkpoint nag in sibling Claude Code
  # windows that didn't run /forge themselves. See session_owns_forge().
  session_owns_forge || exit 0

  # Pip on strike — suppress nag. User cannot write a checkpoint while tool
  # use is blocked, and every response triggers another Stop hook fire,
  # producing a deadlock loop. Resume nagging when strike lifts naturally.
  if is_pip_on_strike; then
    exit 0
  fi

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
# Auto-archive: move task files with `status: resolved` frontmatter from tasks/open/
# to tasks/resolved/. Routes by file shape:
#   - top-level *.md in tasks/open/   → standalone task; mv file
#   - umbrella.md inside subfolder    → umbrella; mv whole subfolder
#   - other file inside subfolder     → sub-task in umbrella; SKIP (per the convention
#                                       that resolved sub-tasks stay alongside open
#                                       siblings until the umbrella itself resolves)
#
# Scans both the active project's vault dir and _shared. Silent when nothing pending.
# Requires VAULT_PATH/.git (auto-archive without git would lose the moves silently).
do_auto_archive() {
  [ -d "$VAULT_PATH/.git" ] || return 0

  local roots=()
  [ -d "$VAULT_DIR/tasks/open" ] && roots+=("$VAULT_DIR")
  [ -d "$VAULT_PATH/_shared/tasks/open" ] && roots+=("$VAULT_PATH/_shared")
  [ ${#roots[@]} -eq 0 ] && return 0

  local moved_count=0
  local moved_list=""
  local root open_dir resolved_dir f status base parent_dir parent_base

  for root in "${roots[@]}"; do
    open_dir="$root/tasks/open"
    resolved_dir="$root/tasks/resolved"
    mkdir -p "$resolved_dir"

    # Use find with -print0 in case any path contains spaces (vault paths can)
    while IFS= read -r -d '' f; do
      # Parse `status:` from frontmatter (between the first two `---` lines).
      # Strip optional surrounding quotes/whitespace.
      status=$(awk '
        /^---[[:space:]]*$/ { c++; if (c==2) exit; next }
        c==1 && /^status:/ {
          sub(/^status:[[:space:]]*/, "")
          gsub(/^["'"'"']|["'"'"']$/, "")
          gsub(/[[:space:]]+$/, "")
          print
          exit
        }
      ' "$f" 2>/dev/null)

      [ "$status" = "resolved" ] || continue

      base=$(basename "$f")
      parent_dir=$(dirname "$f")
      parent_base=$(basename "$parent_dir")

      if [ "$base" = "umbrella.md" ] && [ "$parent_dir" != "$open_dir" ]; then
        # Umbrella — move whole containing subfolder.
        # Try git mv first (preserves single-rename in status); fall back to plain mv
        # if anything inside is untracked (git mv fails partial-fail on mixed states).
        if git -C "$VAULT_PATH" mv "${parent_dir#$VAULT_PATH/}" "${resolved_dir#$VAULT_PATH/}/$parent_base" 2>/dev/null \
          || mv "$parent_dir" "$resolved_dir/$parent_base" 2>/dev/null; then
          moved_count=$((moved_count + 1))
          moved_list="${moved_list}  - ${parent_base}/ (umbrella, whole folder)"$'\n'
        else
          echo "[auto-archive] WARN: failed to mv umbrella subfolder $parent_base/" >&2
        fi
      elif [ "$parent_dir" = "$open_dir" ]; then
        # Standalone task or issue at top level. Same try-git-then-plain pattern —
        # uncommitted task files are valid (status:resolved set during the same session
        # the work shipped, before the commit lands).
        if git -C "$VAULT_PATH" mv "${f#$VAULT_PATH/}" "${resolved_dir#$VAULT_PATH/}/$base" 2>/dev/null \
          || mv "$f" "$resolved_dir/$base" 2>/dev/null; then
          moved_count=$((moved_count + 1))
          moved_list="${moved_list}  - $base"$'\n'
        else
          echo "[auto-archive] WARN: failed to mv standalone task $base" >&2
        fi
      fi
      # else: sub-task inside an umbrella subfolder (not named umbrella.md) — skip per punt
    done < <(find "$open_dir" -type f -name '*.md' -print0 2>/dev/null)
  done

  if [ "$moved_count" -gt 0 ]; then
    echo ""
    echo "--- Auto-archive ---"
    echo "Moved $moved_count resolved task(s) to tasks/resolved/:"
    printf "%s" "$moved_list"
    echo "Update BACKLOG to remove these rows."
  fi
}

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

  # Auto-archive resolved tasks before reporting vault state — so the dirty count
  # downstream reflects the post-archive moves (signal to user that there are
  # uncommitted moves to commit).
  do_auto_archive

  # Install drift — surface if Forge runtime is behind the source repo.
  do_check_install_drift

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

    # Drift warning: nudge when any threshold is exceeded.
    local vault_last_commit_age_days=0
    local last_commit_ts
    last_commit_ts=$(git -C "$VAULT_PATH" log -1 --format=%ct 2>/dev/null || echo 0)
    if [ "$last_commit_ts" -gt 0 ]; then
      vault_last_commit_age_days=$(( ( $(date +%s) - last_commit_ts ) / 86400 ))
    fi

    if [ "$vault_dirty" -ge "$VAULT_DRIFT_DIRTY_FILES" ] \
      || [ "$vault_ahead" -ge "$VAULT_DRIFT_COMMITS_AHEAD" ] \
      || [ "$vault_last_commit_age_days" -ge "$VAULT_DRIFT_DAYS_SINCE" ]; then
      echo "[!] Vault drift detected — commit + push when you reach a natural pause."
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

  # Ownership chip: ⚒ = this session owns the marker, ⚠ = another window owns it.
  # Makes session-isolation visible — sibling Claude Code windows that didn't run /forge
  # see the warning and know Forge hooks are gated off here. Legacy plain-string markers
  # preserve old global behavior (helper returns true → ⚒ everywhere, like before).
  local project_chip
  if session_owns_forge; then
    project_chip="⚒ $PROJECT_NAME"
  else
    project_chip=$(printf "\033[33m⚠ %s (other window)\033[0m" "$PROJECT_NAME")
  fi

  echo "$project_chip | 🌿 ${branch:-n/a} | $indicator"
}

# ── Install drift check ───────────────────────────────────────────────
# Surface "Forge install is N commits behind upstream" at session entry so users
# know to re-run install.sh. Cached-state only (no network) — pairs with the
# explicit `check-install` subcommand below for an active fetch+check.
#
# Reads FORGE_REPO from forge.conf. Silent when in sync AND fetched in last 7 days.
do_check_install_drift() {
  local forge_repo
  forge_repo=$(grep '^FORGE_REPO=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
  [ -z "$forge_repo" ] && return 0
  [ -d "$forge_repo/.git" ] || return 0

  local behind ahead
  behind=$(git -C "$forge_repo" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
  ahead=$(git -C "$forge_repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)

  # Stale-fetch warning — user hasn't `git fetch`'d in a week.
  local fetch_head="$forge_repo/.git/FETCH_HEAD"
  local fetch_age_days=99999
  if [ -f "$fetch_head" ]; then
    local fetch_mtime now
    fetch_mtime=$(stat -f %m "$fetch_head" 2>/dev/null || stat -c %Y "$fetch_head" 2>/dev/null || echo 0)
    now=$(date +%s)
    fetch_age_days=$(( (now - fetch_mtime) / 86400 ))
  fi

  if [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ] && [ "$fetch_age_days" -lt 7 ]; then
    return 0  # silent — in sync and recently fetched
  fi

  echo ""
  echo "--- Install state ---"
  if [ "$behind" -gt 0 ]; then
    echo "[!] Forge install is $behind commit(s) behind upstream."
    echo "    Update: (cd $forge_repo && git pull && ./install.sh)"
  fi
  if [ "$ahead" -gt 0 ]; then
    echo "    Local: $ahead commit(s) ahead of upstream (maintainer-side work)."
  fi
  if [ "$fetch_age_days" -ge 7 ] && [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
    echo "Last upstream fetch: $fetch_age_days days ago."
    echo "    Refresh: git -C $forge_repo fetch  (then re-run /forge to recheck)"
  fi
}

# ── Subcommand: check-install ─────────────────────────────────────────
# Explicit "fetch + report" — call this when the user wants an active drift
# check (vs the cached check baked into do_recover). Useful as a slash-command
# target or shell alias when you've been working a while and want a fresh read.
do_check_install() {
  local forge_repo
  forge_repo=$(grep '^FORGE_REPO=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
  if [ -z "$forge_repo" ] || [ ! -d "$forge_repo/.git" ]; then
    echo "FORGE_REPO not configured or not a git repo — nothing to check."
    return 0
  fi

  echo "Fetching from upstream..."
  if ! git -C "$forge_repo" fetch --quiet 2>&1; then
    echo "[!] git fetch failed (offline? auth?). Falling back to cached state."
  fi
  do_check_install_drift
  # If we just fetched and result is silent, do_check_install_drift returned
  # nothing — surface a confirmation so the user knows the check ran.
  local behind ahead
  behind=$(git -C "$forge_repo" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
  ahead=$(git -C "$forge_repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  if [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
    echo "Forge install is in sync with upstream."
  fi
}

# ── Subcommand: wrap-up-state ─────────────────────────────────────────
# Returns Petra's wrap-up signal as one of:
#   too_early    — session < WRAP_UP_TOO_EARLY_MIN; suppress wrap-up suggestions
#   eod_window   — within WRAP_UP_EOD_WINDOW_MIN of preferred_end_of_day; PROACTIVELY nudge
#   past_eod     — past preferred_end_of_day; nudge harder
#   mid_session  — neither extreme; no nudge either way
#   unknown      — no marker, no preferred_end_of_day, or stat failed; default to silent
#
# Reads:
#   - $MARKER mtime as session-age proxy (when /forge entered)
#   - $VAULT_PATH/_shared/wellness-preferences.json for preferred_end_of_day (HH:MM)
#
# Petra consults this from her SKILL.md "wrap-up state awareness" rule before
# suggesting wrap-up mid-session.
WRAP_UP_TOO_EARLY_MIN=60
WRAP_UP_EOD_WINDOW_MIN=60

do_wrap_up_state() {
  # Session age — minutes since marker mtime (when /forge was entered)
  if [ ! -f "$MARKER" ]; then
    echo "unknown"
    return 0
  fi
  local marker_mtime now session_age_min
  marker_mtime=$(stat -f %m "$MARKER" 2>/dev/null || stat -c %Y "$MARKER" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "$marker_mtime" -eq 0 ]; then
    echo "unknown"
    return 0
  fi
  session_age_min=$(( (now - marker_mtime) / 60 ))

  # Too-early gate — session just started, no wrap-up talk
  if [ "$session_age_min" -lt "$WRAP_UP_TOO_EARLY_MIN" ]; then
    echo "too_early"
    return 0
  fi

  # EOD window — needs preferred_end_of_day from wellness prefs
  local prefs="$VAULT_PATH/_shared/wellness-preferences.json"
  if [ ! -f "$prefs" ]; then
    echo "mid_session"
    return 0
  fi
  local eod
  eod=$(jq -r '.preferred_end_of_day // ""' "$prefs" 2>/dev/null)
  if [ -z "$eod" ] || [ "$eod" = "null" ]; then
    echo "mid_session"
    return 0
  fi

  # Compare current HH:MM to EOD HH:MM (minutes-since-midnight)
  local now_hm eod_min now_min minutes_to_eod
  now_hm=$(date +%H:%M)
  eod_min=$(echo "$eod" | awk -F: '{print ($1*60)+$2}' 2>/dev/null)
  now_min=$(echo "$now_hm" | awk -F: '{print ($1*60)+$2}' 2>/dev/null)
  if [ -z "$eod_min" ] || [ -z "$now_min" ]; then
    echo "mid_session"
    return 0
  fi
  minutes_to_eod=$((eod_min - now_min))

  if [ "$minutes_to_eod" -le 0 ]; then
    echo "past_eod"
  elif [ "$minutes_to_eod" -le "$WRAP_UP_EOD_WINDOW_MIN" ]; then
    echo "eod_window"
  else
    echo "mid_session"
  fi
}

# ── Subcommand: vault-sync ────────────────────────────────────────────
# Walk the vault git status, group dirty files by top-level directory, suggest a
# commit message per group. Default mode prints a report and exits. `--commit`
# runs an interactive walkthrough: Y/N per group, runs git add+commit, then asks
# to push. Skipped groups stay unstaged for the user to handle later.
#
# Bash-3.2 compatible (no associative arrays). Designed to be safe to re-run.
do_vault_sync() {
  local commit_mode=false
  if [ "${1:-}" = "--commit" ]; then
    commit_mode=true
  fi

  if [ ! -d "$VAULT_PATH/.git" ]; then
    echo "Vault not under git ($VAULT_PATH). Run \`git -C $VAULT_PATH init\` to enable vault-sync."
    return 0
  fi

  # Refuse if anything is already staged — vault-sync owns the staging area.
  local pre_staged
  pre_staged=$(git -C "$VAULT_PATH" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  if [ "$pre_staged" -gt 0 ]; then
    echo "[!] $pre_staged file(s) already staged in the vault. vault-sync won't touch them."
    echo "    Commit or unstage them first, then re-run."
    return 1
  fi

  local dirty_short
  dirty_short=$(git -C "$VAULT_PATH" status --short 2>/dev/null)
  if [ -z "$dirty_short" ]; then
    echo "Vault clean. Nothing to sync."
    return 0
  fi

  # Extract paths from `git status --short` output, handling renames (" R old -> new").
  local dirty_paths
  dirty_paths=$(echo "$dirty_short" | awk '{
    $1=""; sub(/^[[:space:]]+/, "")
    if (/ -> /) sub(/.*-> /, "")
    print
  }')

  # Compute unique top-level dirs in first-seen order.
  local toplevels
  toplevels=$(echo "$dirty_paths" | awk -F/ '
    NF==1 { key="(root)" }
    NF>1  { key=$1 }
    !seen[key]++ { print key }
  ')

  echo "=== Vault sync ==="
  if [ "$commit_mode" = false ]; then
    echo "Report mode. Re-run with --commit to interactively commit + push."
  fi

  local total_committed=0

  while IFS= read -r toplevel; do
    [ -z "$toplevel" ] && continue
    echo ""
    echo "--- Group: $toplevel ---"

    local files
    if [ "$toplevel" = "(root)" ]; then
      files=$(echo "$dirty_paths" | awk -F/ 'NF==1 {print}')
    else
      files=$(echo "$dirty_paths" | awk -F/ -v k="$toplevel" 'NF>1 && $1==k {print}')
    fi

    echo "$files" | sed '/^$/d' | sed 's/^/  /'

    # Suggested commit message — based on top-level dir + first-file path shape.
    local suggested_msg first_file project_path
    case "$toplevel" in
      _shared)    suggested_msg="shared: update cross-project vault state" ;;
      _templates) suggested_msg="templates: update vault templates" ;;
      _meta)      suggested_msg="meta: update vault metadata" ;;
      "(root)")   suggested_msg="vault: root-level updates" ;;
      *)
        first_file=$(echo "$files" | head -1)
        # If path looks like ENV/PROJECT/..., scope is ENV/PROJECT.
        if echo "$first_file" | grep -q '^[^/]\+/[^/]\+/'; then
          project_path=$(echo "$first_file" | cut -d/ -f1-2)
          suggested_msg="$project_path: vault updates"
        else
          suggested_msg="$toplevel: vault updates"
        fi
        ;;
    esac
    echo "  → suggested commit: \"$suggested_msg\""

    if [ "$commit_mode" = true ]; then
      local answer
      answer=$(prompt_or_default "  Commit this group? [Y/n]: " "Y")
      case "${answer:-Y}" in
        [Yy]*|"")
          while IFS= read -r f; do
            [ -z "$f" ] && continue
            git -C "$VAULT_PATH" add "$f" 2>/dev/null
          done <<< "$files"
          if git -C "$VAULT_PATH" commit -m "$suggested_msg" >/dev/null 2>&1; then
            echo "  ✓ committed"
            total_committed=$((total_committed + 1))
          else
            echo "  ✗ commit failed (see git status)"
          fi
          ;;
        *)
          echo "  skipped"
          ;;
      esac
    fi
  done <<< "$toplevels"

  if [ "$commit_mode" = true ] && [ "$total_committed" -gt 0 ]; then
    echo ""
    local push_answer
    push_answer=$(prompt_or_default "Push $total_committed commit(s) to origin? [Y/n]: " "Y")
    case "${push_answer:-Y}" in
      [Yy]*|"")
        if git -C "$VAULT_PATH" push 2>&1; then
          echo "✓ pushed"
        else
          echo "✗ push failed — run \`git -C $VAULT_PATH push\` manually"
        fi
        ;;
      *)
        echo "skipped push — $total_committed commit(s) staged locally"
        ;;
    esac
  fi

  echo ""
  echo "================="
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
  vault-sync)        do_vault_sync "${@:2}" ;;
  wrap-up-state)     do_wrap_up_state ;;
  check-install)     do_check_install ;;
  *)
    echo "Usage: forge-context.sh {post-tool|gate|stop|recover|reconcile-marker|status|vault-sync|wrap-up-state|check-install}" >&2
    exit 1
    ;;
esac
