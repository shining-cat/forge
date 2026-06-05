#!/bin/bash
# forge-context.sh — Forge session context layer
# Called by Claude Code hooks (PostToolUse, PreToolUse, Stop) and skills.
# Manages breadcrumbs, checkpoint nudges, gate logic, and recovery prompts.

set -euo pipefail

HOME_DIR="$HOME"

# Resolve marker path from forge.conf VAULT_PATH
# Allow tests to override the config path
FORGE_CONF="${FORGE_CONF_OVERRIDE:-$HOME_DIR/.claude/forge.conf}"
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
STOP_COUNT_FILE="$VAULT_PATH/_shared/forge-session-stops"
FRICTION_LOG="$VAULT_PATH/_shared/friction-log.md"
FRICTION_CLASSIFIED="$VAULT_PATH/_shared/friction-classified.json"
# Catalog defaults to source-of-truth; tests can override
FORGE_PATTERN_CATALOG="${FORGE_PATTERN_CATALOG:-$HOME_DIR/.claude/skills/forge/references/script-replacement-patterns.md}"

# Vault drift thresholds — recover() warns when any one is exceeded
VAULT_DRIFT_COMMITS_AHEAD=5
VAULT_DRIFT_DIRTY_FILES=10
VAULT_DRIFT_DAYS_SINCE=7

# ── Per-repo vault audit helpers (used by do_recover's vault-state section) ──
# Vault can host nested `.git` directories (e.g. Vault/PRO/.git → Schibsted GHEC
# while outer Vault/.git → personal GitHub). Outer's .gitignore excludes the
# nested subtree, so nested drift is invisible to a naive outer-only audit.
# These helpers audit one repo at a time so the driver in do_recover can iterate.

# Build a short, user-readable label for a vault repo: "<rel-path> → <remote-host>".
# Outer repo (path == VAULT_PATH) shows as "vault root". Nested repos show their
# relative subpath. "(no remote)" if no origin is configured.
vault_repo_label() {
  local repo_path="$1"
  local rel host
  if [ "$repo_path" = "$VAULT_PATH" ]; then
    rel="vault root"
  else
    rel="${repo_path#$VAULT_PATH/}/"
  fi
  # Extract the host (or SSH alias) from the origin URL: works for
  #   https://host/owner/repo(.git)?           → host
  #   git@host:owner/repo(.git)?               → host
  #   ssh://git@host[:port]/owner/repo(.git)?  → host
  # If origin is missing, host stays empty (label drops the arrow segment).
  host="$(git -C "$repo_path" remote get-url origin 2>/dev/null \
    | sed -E 's#^https?://([^/]+)/.*#\1#; s#^ssh://[^@]+@([^/:]+).*#\1#; s#^[^@]+@([^:]+):.*#\1#' \
    || true)"
  if [ -n "$host" ]; then
    echo "$rel → $host"
  else
    echo "$rel (no remote)"
  fi
}

# Audit one vault repo. Prints one status line prefixed with [label] (clean or
# detailed counts), and returns 0 if any drift threshold trips, 1 otherwise.
# The caller decides what to do with the aggregated drift signal.
audit_one_vault_repo() {
  local repo_path="$1" label="$2" has_upstream="$3"
  local dirty ahead behind untracked_dirs status_text
  dirty="$(git -C "$repo_path" status --short 2>/dev/null | wc -l | tr -d ' ')"
  ahead="$(git -C "$repo_path" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  behind="$(git -C "$repo_path" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
  untracked_dirs="$(git -C "$repo_path" status --short 2>/dev/null \
    | awk '/^\?\?/ {print $2}' | awk -F/ '{print $1}' | sort -u | wc -l | tr -d ' ')"

  if [ "$dirty" -eq 0 ] && [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
    if [ "$has_upstream" -eq 1 ]; then
      status_text="Clean, in sync with origin."
    else
      status_text="Clean. (No remote — stays on your laptop.)"
    fi
    echo "[$label] $status_text"
  else
    local parts=()
    [ "$dirty" -gt 0 ]          && parts+=("Dirty: $dirty")
    [ "$untracked_dirs" -gt 0 ] && parts+=("Untracked dirs: $untracked_dirs")
    [ "$ahead" -gt 0 ]          && parts+=("Unpushed: $ahead")
    [ "$behind" -gt 0 ]         && parts+=("Behind: $behind")
    # Join with " · " separator (IFS-based join only takes the first char).
    local joined
    printf -v joined '%s · ' "${parts[@]}"
    joined="${joined% · }"
    echo "[$label] $joined"
  fi

  # Drift threshold check — return 0 (drift) if any threshold trips, else 1.
  local last_ts age_days=0
  last_ts="$(git -C "$repo_path" log -1 --format=%ct 2>/dev/null || echo 0)"
  [ "$last_ts" -gt 0 ] && age_days=$(( ( $(date +%s) - last_ts ) / 86400 ))

  if [ "$dirty" -ge "$VAULT_DRIFT_DIRTY_FILES" ] \
    || [ "$ahead" -ge "$VAULT_DRIFT_COMMITS_AHEAD" ] \
    || [ "$age_days" -ge "$VAULT_DRIFT_DAYS_SINCE" ]; then
    return 0
  fi
  return 1
}

# Brain-dump nag interval (minutes since last entry) — override via forge.conf
# by setting `BRAINDUMP_INTERVAL_MIN=<int>`. Default 10. Tester item #7.
BRAINDUMP_INTERVAL_MIN="$(grep '^BRAINDUMP_INTERVAL_MIN=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- || true)"
BRAINDUMP_INTERVAL_MIN="${BRAINDUMP_INTERVAL_MIN:-10}"

# End-of-week day (ISO day-of-week, Mon=1..Sun=7). Default 5 (Friday). On this
# day, do_wrap_up_state upgrades eod_window→eow_window and past_eod→past_eow.
EOW_DAY="$(grep '^EOW_DAY=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- || true)"
EOW_DAY="${EOW_DAY:-5}"

# Look-ahead horizon (minutes) for do_next_meeting. Default 30.
MEETING_WINDOW_MIN="$(grep '^MEETING_WINDOW_MIN=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- || true)"
MEETING_WINDOW_MIN="${MEETING_WINDOW_MIN:-30}"

# Gap (in days) after which a weekly wrap-up is "due" again. Default 5 — so a
# wrap done on Friday morning won't re-trigger if the user re-enters Forge
# Friday afternoon, but a wrap not done by next Wednesday will. Override via
# forge.conf or env (tests use env=0 to force `due`).
FORGE_WEEKLY_WRAP_GAP_DAYS="${FORGE_WEEKLY_WRAP_GAP_DAYS:-$(grep '^FORGE_WEEKLY_WRAP_GAP_DAYS=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- || true)}"
FORGE_WEEKLY_WRAP_GAP_DAYS="${FORGE_WEEKLY_WRAP_GAP_DAYS:-5}"

# Checkpoint-nag suppression (do_stop) — both gates must pass for the nag to fire.
# Reframes the nag from "clock-driven" ("X minutes since checkpoint") to
# "activity-driven" ("work done in this session that isn't recorded"). Covers
# end-of-day → start-of-day, lunch pauses, conference talks, etc.
NAG_SUPPRESS_GRACE_MIN=30        # A — first N min of any fresh session entry: no nag
NAG_SUPPRESS_ACTIVITY_STOPS=10   # C — until N Stop events in this session: no nag

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

# Given a project name, scan $VAULT_PATH/*/{project}/ to determine which ENV
# (top-level vault subdirectory) contains it. Echoes the ENV name on stdout,
# empty if not found or ambiguous. Marker JSON does not store ENV — this is
# the canonical way to resolve project→ENV.
extract_marker_env() {
  local project="$1"
  [ -z "$project" ] && return 0
  [ -z "${VAULT_PATH:-}" ] && return 0
  local match=""
  local count=0
  local d env
  for d in "$VAULT_PATH"/*/"$project"; do
    [ -d "$d" ] || continue
    env=$(basename "$(dirname "$d")")
    case "$env" in
      _*) continue ;;  # skip _shared, _templates, _meta
    esac
    match="$env"
    count=$((count + 1))
  done
  if [ "$count" = "1" ]; then
    echo "$match"
  fi
  return 0
}

# Returns the marker's `started_at` field as a Unix epoch (seconds), or empty
# if unavailable / unparseable. Used by do_stop's A+C suppression to compute
# session age and detect fresh sessions for counter reset.
get_marker_started_at_epoch() {
  [ ! -f "$MARKER" ] && return 0
  local started_at_iso
  started_at_iso=$(jq -r '.started_at // empty' "$MARKER" 2>/dev/null)
  [ -z "$started_at_iso" ] && return 0
  # set-marker writes ISO 8601 like 2026-05-19T15:20:05+0200 (date '+%Y-%m-%dT%H:%M:%S%z').
  # macOS date -j parses with the matching format spec.
  date -j -f '%Y-%m-%dT%H:%M:%S%z' "$started_at_iso" '+%s' 2>/dev/null || true
}

# Increment the per-session Stop counter and echo the new value.
# State file shape (two lines): cached_started_at\ncount\n
# When the marker's started_at differs from the cached one, treats it as a new
# session and resets to 0 before incrementing.
# Returns 0 (echoed) if the marker has no started_at — in that case the gate
# can't make a useful decision and the caller should treat as "passes through".
increment_stop_count() {
  local current_started_at cached_started_at cached_count
  current_started_at=$(jq -r '.started_at // empty' "$MARKER" 2>/dev/null)
  if [ -z "$current_started_at" ]; then
    echo "0"
    return 0
  fi

  if [ -f "$STOP_COUNT_FILE" ]; then
    cached_started_at=$(awk 'NR==1' "$STOP_COUNT_FILE" 2>/dev/null)
    cached_count=$(awk 'NR==2' "$STOP_COUNT_FILE" 2>/dev/null)
  fi

  if [ "${cached_started_at:-}" != "$current_started_at" ]; then
    cached_count=0
  fi

  cached_count=$(( ${cached_count:-0} + 1 ))
  printf '%s\n%d\n' "$current_started_at" "$cached_count" > "$STOP_COUNT_FILE"
  echo "$cached_count"
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

# Returns 0 (true) if MAINTAINER_MODE=true in forge.conf, 1 otherwise.
# Used to gate maintainer-only surfaces (open-task audit, BACKLOG staleness
# audit) from session-entry output so end-user mode stays focused on project
# work. Persona-level gates (Petra's proactive suggestions about
# decisions/INDEX/BACKLOG/vault-hygiene/etc.) live in the forge SKILL.md
# "Maintainer mode" section — this script-level gate complements them by
# suppressing the raw audit data that would otherwise feed those suggestions.
is_maintainer_mode() {
  [ -f "$FORGE_CONF" ] || return 1
  grep -q '^MAINTAINER_MODE=true$' "$FORGE_CONF"
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

# Returns 0 if the wellness coach is on strike (tool use blocked), 1 otherwise.
# Used by do_stop and do_post_tool to suppress nags during a strike — without
# this short-circuit, Keeper's Stop hook fires on every response and the user
# cannot satisfy it (writing a checkpoint requires tool calls the strike blocks),
# producing a hook-deadlock loop. See friction log 2026-05-07 — "Hook
# coordination deadlock loop". Fail-open: if wellness file is missing or
# unreadable, treat as not-on-strike (wellness-disabled installs unaffected).
is_wellness_strike_active() {
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

# Resolve project repo directory by scanning configured REPO_ROOTS.
# REPO_ROOTS in forge.conf is a colon-separated list of directories to scan.
# If unset, falls back to the grandparent of FORGE_REPO (derived from the same
# forge.conf) — preserves the maintainer's effective behavior for installs that
# predate REPO_ROOTS becoming an explicit config key, without baking any layout
# convention into forge code. Each root is scanned at depth 1 (flat layout:
# ROOT/project/) and at depth 2 (env-nested layout: ROOT/env/project/),
# case-insensitively. Underscore-prefixed and Vault* directories at the env
# level are skipped.
# Emits stderr warning + empty stdout if no match.
get_project_dir() {
  local project="$1"
  local target_lower
  target_lower="$(echo "$project" | tr '[:upper:]' '[:lower:]')"

  local repo_roots
  repo_roots="$(grep '^REPO_ROOTS=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- || true)"
  if [ -z "$repo_roots" ]; then
    # Derive from FORGE_REPO's grandparent. Warn once per session so the user
    # knows REPO_ROOTS isn't explicit — re-running install.sh writes it.
    local forge_repo
    forge_repo="$(grep '^FORGE_REPO=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- || true)"
    if [ -n "$forge_repo" ]; then
      repo_roots="$(dirname "$(dirname "$forge_repo")")"
      local sid="${CLAUDE_CODE_SESSION_ID:-$$}"
      local infer_marker="/tmp/forge-context-repo-roots-inferred-${sid}"
      if [ ! -f "$infer_marker" ]; then
        echo "[forge-context] REPO_ROOTS not set in forge.conf — using inferred '$repo_roots' (FORGE_REPO grandparent). Re-run install.sh to make this explicit." >&2
        touch "$infer_marker"
      fi
    fi
  fi

  local root sub_dir sub_name proj_dir proj_name
  local IFS=':'
  for root in $repo_roots; do
    # Expand leading ~ to $HOME so users can write paths the natural way.
    case "$root" in
      "~"*) root="$HOME${root#\~}" ;;
    esac
    [ -d "$root" ] || continue
    # Depth 1: flat layout (ROOT/project/)
    for proj_dir in "$root"/*/; do
      [ -d "$proj_dir" ] || continue
      proj_name="$(basename "$proj_dir")"
      if [ "$(echo "$proj_name" | tr '[:upper:]' '[:lower:]')" = "$target_lower" ]; then
        echo "${proj_dir%/}"
        return 0
      fi
    done
    # Depth 2: env-nested layout (ROOT/env/project/)
    for sub_dir in "$root"/*/; do
      [ -d "$sub_dir" ] || continue
      sub_name="$(basename "$sub_dir")"
      case "$sub_name" in _*|Vault*) continue ;; esac
      for proj_dir in "$sub_dir"*/; do
        [ -d "$proj_dir" ] || continue
        proj_name="$(basename "$proj_dir")"
        if [ "$(echo "$proj_name" | tr '[:upper:]' '[:lower:]')" = "$target_lower" ]; then
          echo "${proj_dir%/}"
          return 0
        fi
      done
    done
  done
  # Emit warning once per session — repeated misses during a single session
  # are the same miss; cascading through every PreToolUse hook spams stderr
  # and drowns useful output. Marker is keyed on session id so concurrent
  # sessions each get one warning, and PID-based fallback ensures uniqueness
  # outside of Claude Code (e.g. manual script runs).
  local sid="${CLAUDE_CODE_SESSION_ID:-$$}"
  local warn_marker="/tmp/forge-context-warned-${sid}"
  if [ ! -f "$warn_marker" ]; then
    echo "[forge-context] no project repo found for '$project' under: $repo_roots" >&2
    touch "$warn_marker" 2>/dev/null || true
  fi
  return 1
}

# ── Sourceable boundary ─────────────────────────────────────────────────
# Everything below runs only when this file is executed as a script.
# When sourced (e.g., from forge-compaction.sh or forge-session-end.sh to
# reuse the helpers above), VAULT_PATH/MARKER resolution + all helper
# definitions (extract_marker_project,
# session_owns_forge, reconcile_marker, is_wellness_strike_active, get_vault_dir,
# get_project_dir) stay in scope, but no stdin is consumed and no
# subcommand dispatch runs.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# ── Per-subcommand setup ────────────────────────────────────────────────
# Hook subcommands (post-tool, gate, stop) consume a JSON payload on stdin
# from Claude Code. Write subcommands (set-marker, append-braindump) and
# write-adjacent subcommands (vault-sync) are invoked directly by Claude via
# the Bash tool — their stdin is non-TTY but EMPTY, so an unconditional
# `cat` on stdin would block forever waiting for EOF.
#
# Also: set-marker operates on the marker file itself (writes pending/JSON/
# clear), so it MUST skip the marker-existence + project-resolution guards
# below — by definition it runs when the marker is missing or __pending__.
STDIN_JSON=""
SUBCMD_PEEK="${1:-}"
case "$SUBCMD_PEEK" in
  set-marker|append-friction|pin-friction|archive-friction-entries|harvest-friction|promote-friction|bootstrap-harvest|audit-prose-rules|skill-budgets|framework-budget|bootstrap-classify|resolve-task|friction-tail|weekly-wrap-due|mark-weekly-wrap-done|substrate-check|review-sync)
    # No stdin read, no guards. These operate on marker/shared state only.
    # resolve-task scans the whole vault by slug — it doesn't need a resolved
    # active project, and is safe to invoke even when Forge isn't active
    # (e.g. from a post-commit hook in a sibling Claude Code window).
    # friction-tail reads $VAULT_PATH/_shared/friction-log.md directly — no
    # project context needed.
    # skill-budgets reads $FORGE_REPO/core/skill-budgets.conf directly and
    # doesn't need marker context — also future-proofs against pre-commit /
    # `gh pr comment` invocations that won't have a tty.
    # substrate-check inspects $TMUX env + `command -v tmux` — fully project-
    # independent; routed through the script so the substrate detection
    # inherits the existing allowlist instead of prompting on every entry.
    ;;
  append-braindump|vault-sync|wrap-up-state|check-install|reconcile-marker|recover)
    # No stdin read. Guards still apply — these need a resolved project.
    if [ ! -f "$MARKER" ]; then exit 0; fi
    PROJECT_NAME="$(extract_marker_project)"
    if [ -z "$PROJECT_NAME" ]; then exit 0; fi
    VAULT_DIR="$(get_vault_dir "$PROJECT_NAME")"
    PROJECT_DIR="$(get_project_dir "$PROJECT_NAME")"
    CHECKPOINT_FILE="$VAULT_DIR/current-checkpoint.md"
    BRAINDUMP_FILE="$VAULT_DIR/braindump.md"
    BREADCRUMBS_FILE="$VAULT_DIR/breadcrumbs.log"
    ;;
  *)
    # Hook subcommands (post-tool, gate, stop) + status (called by
    # statusline.sh with session_id JSON piped in via `echo "$input" | ...`)
    # + unknown subcommands — read stdin if present, then apply guards.
    #
    # NOTE: `status` MUST live in this branch — statusline.sh's subprocess
    # context does NOT inherit $CLAUDE_CODE_SESSION_ID from Claude Code's
    # parent, so session_owns_forge depends on STDIN_JSON for the comparison.
    # Putting status in the no-stdin branch causes the ⚠ "(other window)"
    # chip to render in every window. See 2026-05-12 friction-log entry
    # (3-bug statusline stack) — this is the regression-guard comment.
    if [ ! -t 0 ]; then
      STDIN_JSON="$(cat)"
    fi
    if [ ! -f "$MARKER" ]; then exit 0; fi
    PROJECT_NAME="$(extract_marker_project)"
    if [ -z "$PROJECT_NAME" ]; then exit 0; fi
    VAULT_DIR="$(get_vault_dir "$PROJECT_NAME")"
    PROJECT_DIR="$(get_project_dir "$PROJECT_NAME")"
    CHECKPOINT_FILE="$VAULT_DIR/current-checkpoint.md"
    BRAINDUMP_FILE="$VAULT_DIR/braindump.md"
    BREADCRUMBS_FILE="$VAULT_DIR/breadcrumbs.log"
    ;;
esac

# ── Helper: age of checkpoint in minutes ────────────────────────────────
# Returns min(wall-clock-age, gap-since-last-signal) so a 13h checkpoint after
# a 14h Forge-idle gap (overnight, weekend, vacation) isn't flagged stale —
# the user hasn't been working, so the checkpoint isn't actually behind.
# Sentinel: when gap == 999999999 (no signals — fresh install), fall through
# to raw age so the nag still fires on a genuinely empty vault.
get_checkpoint_age_minutes() {
  if [ ! -f "$CHECKPOINT_FILE" ]; then
    echo "9999"
    return
  fi
  local now mtime raw_age_sec gap effective_sec
  now="$(date +%s)"
  mtime="$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)"
  raw_age_sec=$(( now - mtime ))

  gap="$("$HOME/.claude/scripts/forge-gap-since-last-signal.sh" 2>/dev/null || echo 999999999)"
  if [ "$gap" = "999999999" ] || [ "$gap" -ge "$raw_age_sec" ]; then
    effective_sec=$raw_age_sec
  else
    effective_sec=$gap
  fi
  echo $(( effective_sec / 60 ))
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

  # Wellness coach on strike — breadcrumb still recorded above, but suppress all nags
  # below (brain-dump, push/PR nudge). User can't act on them during a strike,
  # and Keeper's Stop hook would loop on the resulting empty responses.
  # NOTE: trailer parsing (further down) is mechanical and also gated by
  # strike — during a strike there are no git commits to parse anyway, so
  # this is moot in practice.
  if is_wellness_strike_active; then
    return 0
  fi

  # Parse the Bash command once for use by trailer parsing + push/PR nudge.
  local command
  command="$(echo "$STDIN_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)" || command=""

  # ── Plan C: auto-resolve tasks from `Resolves task:` commit trailers ─
  # When `git commit` lands, scan the just-committed message for
  # `Resolves task: <slug>` trailers and flip matching open-task files to
  # tasks/resolved/. Pattern reuses do_gate's matcher for consistency.
  #
  # MUST run before the brain-dump section: that section has early `return 0`
  # branches (subagent guard, just-dumped, per-response cooldown) that would
  # otherwise skip trailer parsing whenever a recent brain-dump nag fired.
  # Trailer parsing is mechanical work, not a notification — it should fire
  # on every commit regardless of nag-throttling state.
  #
  # Requires `git -C <path>` form so we know which repo to inspect. The
  # bare `git commit` form (relies on cwd) is skipped — post-tool runs
  # from Claude Code's wd, not the user's commit wd, so cwd is unreliable.
  # All commits driven through Claude follow the `git -C` convention
  # anyway (MEMORY.md: "NEVER use cd && git, ALWAYS use git -C").
  #
  # Idempotent: do_resolve_task no-ops on already-resolved files. If the
  # commit failed (hook reject), HEAD is unchanged and we re-parse the
  # previous commit's trailers — still safe.
  case "$command" in
    *"git commit"*|*"git -C"*commit*)
      local repo_dir=""
      if [[ "$command" =~ git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
        repo_dir="${BASH_REMATCH[1]}"
      fi
      if [ -n "$repo_dir" ] && [ -d "$repo_dir/.git" ]; then
        local commit_msg commit_sha pr_spec="" trailer_slug
        commit_msg="$(git -C "$repo_dir" log -1 --format=%B HEAD 2>/dev/null || true)"
        commit_sha="$(git -C "$repo_dir" log -1 --format=%H HEAD 2>/dev/null || true)"
        if [ -n "$commit_msg" ]; then
          if [[ "$commit_msg" =~ ([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+#[0-9]+) ]]; then
            pr_spec="${BASH_REMATCH[1]}"
          fi
          while IFS= read -r trailer_slug; do
            [ -z "$trailer_slug" ] && continue
            "$0" resolve-task "$trailer_slug" "$commit_sha" "$pr_spec" >&2 || true
          done < <(printf '%s\n' "$commit_msg" | sed -n 's/^Resolves task:[[:space:]]*\(.*\)$/\1/p' | tr -d '\r')
        fi
      fi
      ;;
  esac

  # ── Brain dump prompt (interval-driven; tunable + no-novelty skip) ─────
  # Stacked throttle: subagent guard + just-dumped mtime + per-response cooldown
  # + no-novelty marker. Interval threshold is tunable via BRAINDUMP_INTERVAL_MIN
  # in forge.conf (default 10). Tester item #7.
  # Fixes per-tool-call refire pattern (see vault task keeper-braindump-hook-suppress-in-subagents).
  local dump_age checkpoint_age output session_id agent_id now braindump_mtime cooldown_marker cooldown_age last_braindump_line
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

  # No-novelty signal — if the last non-empty line of braindump.md contains
  # the literal "(no new state)" or "(nns)", the user has signaled nothing has
  # changed since the previous entry. Suppress nag until a new entry is
  # appended without the marker. This is the user's explicit escape hatch:
  # cheap to write, instantly silences cadence-driven nagging, self-clears on
  # the next real entry.
  if [ -f "$BRAINDUMP_FILE" ]; then
    last_braindump_line="$(awk 'NF {line=$0} END {print line}' "$BRAINDUMP_FILE" 2>/dev/null)"
    case "$last_braindump_line" in
      *"(no new state)"*|*"(nns)"*)
        return 0
        ;;
    esac
  fi

  if [ "$dump_age" -ge "$BRAINDUMP_INTERVAL_MIN" ]; then
    # Touch the cooldown marker before emitting (suppresses next tool call within 60s).
    [ -n "$session_id" ] && touch "/tmp/forge-braindump-cooldown-${session_id}" 2>/dev/null
    output="{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"[Keeper] Brain dump due (${dump_age}min since last). Append 2-3 lines to braindump.md: what you're working on, what you just figured out, what's next. If genuinely nothing new, append '(no new state)' to silence until next real entry. File: $BRAINDUMP_FILE\"}}"
  fi

  # ── Push/PR nudge (checkpoint reminder on push or PR creation) ──────
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

  # Wellness coach on strike — suppress nag. User cannot write a checkpoint while tool
  # use is blocked, and every response triggers another Stop hook fire,
  # producing a deadlock loop. Resume nagging when strike lifts naturally.
  if is_wellness_strike_active; then
    exit 0
  fi

  # A+C nag suppression — reframe nag from clock-driven to activity-driven so
  # end-of-day → start-of-day, lunch pauses, etc. don't fire spurious nags.
  # Both gates must pass for the original mtime check to even run.
  local started_at_epoch now_epoch session_age_min stop_count
  started_at_epoch=$(get_marker_started_at_epoch)
  now_epoch=$(date '+%s')
  # Always increment the per-session counter so it reflects reality even when
  # A suppresses (so C is accurate the moment grace expires).
  stop_count=$(increment_stop_count)

  if [ -n "$started_at_epoch" ]; then
    session_age_min=$(( (now_epoch - started_at_epoch) / 60 ))
    # A — entry grace: first N min of any fresh session: no nag
    if [ "$session_age_min" -lt "$NAG_SUPPRESS_GRACE_MIN" ]; then
      exit 0
    fi
  fi
  # C — activity gate: until N Stop events in this session: no nag
  if [ "$stop_count" -lt "$NAG_SUPPRESS_ACTIVITY_STOPS" ]; then
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

# ── Subcommand: resolve-task (Plan C — script-driven task closure) ──────
# Flip a single open task to `status: resolved` and git-mv it to
# tasks/resolved/. Invoked two ways:
#   (1) Directly:  forge-context.sh resolve-task <slug> [<sha>] [<pr-spec>]
#   (2) Auto via do_post_tool: when a `git commit` lands carrying one or more
#       `Resolves task: <slug>` trailers in its message body, do_post_tool
#       re-execs this subcommand per trailer.
#
# Slug match is substring across $VAULT_PATH/**/tasks/open/*.md. Refuses
# (warn, exit 0) on 0 matches or >1 matches — no auto-pick. Idempotent if
# the file is already status: resolved (skips flip, still relocates if
# somehow still in tasks/open/).
#
# Note: pairs with do_auto_archive (which flips nothing but archives
# anything already marked status: resolved). resolve-task does both: flip
# + archive. They're complementary, not redundant — auto-archive cleans up
# resolved-but-not-moved (e.g. manual edits), resolve-task is the
# commit-driven closure path.
do_resolve_task() {
  local slug="${1:-}"
  local sha="${2:-}"
  local pr_spec="${3:-}"
  if [ -z "$slug" ]; then
    echo "[resolve-task] ERR: slug required" >&2
    return 1
  fi
  slug="${slug%.md}"

  if [ -z "${VAULT_PATH:-}" ] || [ ! -d "$VAULT_PATH" ]; then
    echo "[resolve-task] ERR: VAULT_PATH unset or missing ($VAULT_PATH)" >&2
    return 1
  fi

  local matches=() f
  while IFS= read -r -d '' f; do
    matches+=("$f")
  done < <(find "$VAULT_PATH" -type f -name "*${slug}*.md" -path "*/tasks/open/*" -print0 2>/dev/null)

  if [ "${#matches[@]}" -eq 0 ]; then
    echo "[resolve-task] WARN: no open task matching '$slug' — nothing to do" >&2
    return 0
  fi
  if [ "${#matches[@]}" -gt 1 ]; then
    echo "[resolve-task] WARN: ambiguous '$slug' — ${#matches[@]} matches:" >&2
    printf '  %s\n' "${matches[@]}" >&2
    return 0
  fi

  local task_file="${matches[0]}"
  local task_dir task_base task_root resolved_dir today current_status
  task_dir="$(dirname "$task_file")"
  task_base="$(basename "$task_file")"
  task_root="${task_dir%/tasks/open}"
  resolved_dir="$task_root/tasks/resolved"
  mkdir -p "$resolved_dir"
  today="$(date +%Y-%m-%d)"

  current_status=$(awk '
    /^---[[:space:]]*$/ { c++; if (c==2) exit; next }
    c==1 && /^status:/ {
      sub(/^status:[[:space:]]*/, "")
      gsub(/^["'"'"']|["'"'"']$/, "")
      gsub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$task_file" 2>/dev/null)

  # Flip frontmatter in place unless already resolved AND no new pr_spec to record.
  if [ "$current_status" != "resolved" ] || [ -n "$pr_spec" ]; then
    local tmp="$task_file.tmp.$$"
    awk -v today="$today" -v pr_spec="$pr_spec" '
      BEGIN { in_fm=0; fm_count=0; have_resolved=0; have_shipped=0 }
      /^---[[:space:]]*$/ {
        fm_count++
        if (fm_count == 1) { in_fm=1; print; next }
        if (fm_count == 2 && in_fm) {
          if (!have_resolved) print "resolved: " today
          if (!have_shipped && pr_spec != "") print "shipped_via: " pr_spec
          in_fm=0
          print
          next
        }
        print; next
      }
      in_fm && /^status:[[:space:]]/ { print "status: resolved"; next }
      in_fm && /^updated:[[:space:]]/ { print "updated: " today; next }
      in_fm && /^resolved:[[:space:]]/ { print "resolved: " today; have_resolved=1; next }
      in_fm && /^shipped_via:[[:space:]]/ {
        if (pr_spec != "") { print "shipped_via: " pr_spec } else { print }
        have_shipped=1; next
      }
      { print }
    ' "$task_file" > "$tmp" && mv "$tmp" "$task_file"
  fi

  # git mv if vault is a git repo AND the file is tracked; else plain mv.
  local moved=0 rel_from rel_to
  rel_from="${task_file#$VAULT_PATH/}"
  rel_to="${resolved_dir#$VAULT_PATH/}/$task_base"
  if git -C "$VAULT_PATH" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$VAULT_PATH" ls-files --error-unmatch "$rel_from" >/dev/null 2>&1; then
      if git -C "$VAULT_PATH" mv "$rel_from" "$rel_to" 2>/dev/null; then
        moved=1
      fi
    fi
  fi
  if [ "$moved" -eq 0 ]; then
    mv "$task_file" "$resolved_dir/$task_base" 2>/dev/null || {
      echo "[resolve-task] ERR: failed to mv $task_base to resolved/" >&2
      return 1
    }
  fi

  local note=""
  [ -n "$sha" ] && note=" (commit ${sha:0:7})"
  [ -n "$pr_spec" ] && note="${note} (shipped via $pr_spec)"
  echo "[resolve-task] $task_base → tasks/resolved/${note}"
}

# ── Open-task staleness audit (recovery sibling of auto-archive) ────────
# Auto-archive only fires for tasks whose frontmatter already says `status: resolved`.
# The drift pattern (shipped tasks left at `status: open`) is invisible to it. This
# audit surfaces candidates: top-level *.md files in tasks/open/ where
#   - mtime older than STALE_DAYS, AND
#   - filename slug NOT mentioned anywhere in current-checkpoint.md, AND
#   - filename slug NOT present in the project's BACKLOG.md active tables
#     (rows outside the collapsed `<details>` "Recently shipped" history block)
# All three conditions together filter out actively-paused work. The BACKLOG
# crosscheck closes a common false-positive: long-tail open tasks that the
# Keeper has explicitly listed in BACKLOG.md but that aren't enumerated in a
# `session: closed` EOD-summary checkpoint (so the checkpoint-only filter
# misses them after a weekend gap). Visibility-only — never auto-flips
# frontmatter; user/Claude verifies + flips per task.
#
# Also flags `tasks/done/` folders as one-time-migration prompts. `resolved/` is
# the canonical bucket; `done/` is a legacy alias from an older vault layout.
# ── Helper: read a single frontmatter field value ──────────────────────
# Returns the trimmed value (with surrounding quotes stripped), or empty
# string if the field is absent or the file has no frontmatter. Reads
# only between the first two `---` fences so body content with a colon
# (e.g. `## status: blocked` in prose) doesn't leak in.
#
# Usage: value=$(fm_field "$task_file" status)
fm_field() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v key="$key" '
    /^---[[:space:]]*$/ { c++; if (c==2) exit; next }
    c==1 {
      pat = "^" key ":"
      if (match($0, pat)) {
        sub(pat "[[:space:]]*", "")
        gsub(/^["'"'"']|["'"'"']$/, "")
        gsub(/[[:space:]]+$/, "")
        print
        exit
      }
    }
  ' "$file" 2>/dev/null
}

STALE_TASK_DAYS=7
audit_open_tasks_one() {
  local proj_dir="$1"
  local open_dir="$proj_dir/tasks/open"
  local checkpoint="$proj_dir/current-checkpoint.md"
  local backlog="$proj_dir/BACKLOG.md"
  [ -d "$open_dir" ] || return 0

  local now stale_threshold_secs cp_text backlog_active
  now="$(date +%s)"
  stale_threshold_secs=$(( STALE_TASK_DAYS * 86400 ))
  cp_text=""
  [ -f "$checkpoint" ] && cp_text="$(cat "$checkpoint" 2>/dev/null)"

  # Extract BACKLOG content OUTSIDE any `<details>...</details>` block. The
  # convention: active prioritized rows live in plain markdown tables; closed
  # work is collapsed into a `<details>` "Recently shipped" history block at
  # the bottom. We only treat the active region as "Keeper says this is open".
  backlog_active=""
  if [ -f "$backlog" ]; then
    backlog_active="$(awk '
      /<details/    { in_details=1; next }
      /<\/details>/ { in_details=0; next }
      !in_details   { print }
    ' "$backlog" 2>/dev/null)"
  fi

  local f base slug short_slug mtime age_secs age_days
  while IFS= read -r -d '' f; do
    [ "$(dirname "$f")" = "$open_dir" ] || continue

    # Skip tasks whose frontmatter declares they're not actively in scope.
    # Three exclusions, each motivated by a recurring false positive in the
    # 2026-06-05 audit-sweep:
    #   park: true              → intentional plan-prep reference, read at event-time
    #                             (next-migration-playbook-corrections)
    #   status: blocked         → waiting on external dependency
    #                             (PF-1799 — blocked on PF-1718 outcome)
    #   status: needs-refinement → real intent, awaiting design/refinement headspace
    #                             (finn-kb-deeper-integration — awaiting forge cruise velocity)
    # The companion `awaiting:` frontmatter field is informational only —
    # captures *what* needs to happen before the task can move. Audit doesn't
    # read it; the human reading the task does.
    case "$(fm_field "$f" status)" in
      blocked|needs-refinement) continue ;;
    esac
    [ "$(fm_field "$f" park)" = "true" ] && continue

    base="$(basename "$f")"
    slug="${base%.md}"
    short_slug="${slug#????-??-??-}"

    mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
    age_secs=$(( now - mtime ))
    [ "$age_secs" -ge "$stale_threshold_secs" ] || continue

    if [ -n "$cp_text" ]; then
      printf '%s' "$cp_text" | grep -qF "$slug" 2>/dev/null && continue
      printf '%s' "$cp_text" | grep -qF "$short_slug" 2>/dev/null && continue
    fi

    if [ -n "$backlog_active" ]; then
      printf '%s' "$backlog_active" | grep -qF "$slug" 2>/dev/null && continue
      printf '%s' "$backlog_active" | grep -qF "$short_slug" 2>/dev/null && continue
    fi

    age_days=$(( age_secs / 86400 ))
    echo "$age_days|$base"
  done < <(find "$open_dir" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null) \
    | sort -t'|' -k1,1 -rn
}

do_open_task_audit() {
  local stale_blocks="" migration_warnings=""
  local env_dir env_name proj_dir proj_name

  # Iterate concrete envs (skip _shared/_templates) plus _shared explicitly.
  local scan_dirs=()
  for env_dir in "$VAULT_PATH"/*/; do
    [ -d "$env_dir" ] || continue
    env_name="$(basename "$env_dir")"
    case "$env_name" in _*) ;; *) :;; esac
    case "$env_name" in
      _shared) scan_dirs+=("$env_dir") ;;
      _*) continue ;;
      *)
        for proj_dir in "$env_dir"*/; do
          [ -d "$proj_dir" ] || continue
          scan_dirs+=("$proj_dir")
        done
        ;;
    esac
  done

  local scan_dir
  for scan_dir in "${scan_dirs[@]}"; do
    proj_dir="${scan_dir%/}"
    proj_name="$(basename "$(dirname "$proj_dir")")/$(basename "$proj_dir")"
    [ "$(basename "$proj_dir")" = "_shared" ] && proj_name="_shared"

    if [ -d "$proj_dir/tasks/done" ]; then
      local done_count
      done_count="$(find "$proj_dir/tasks/done" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
      migration_warnings="${migration_warnings}  - ${proj_name}: tasks/done/ exists (${done_count} files) — migrate to tasks/resolved/ (canonical bucket)"$'\n'
    fi

    local rows
    rows="$(audit_open_tasks_one "$proj_dir")"
    if [ -n "$rows" ]; then
      stale_blocks="${stale_blocks}  ${proj_name}:"$'\n'
      stale_blocks="${stale_blocks}$(echo "$rows" | awk -F'|' '{printf "    - %s (%dd)\n", $2, $1}')"$'\n'
    fi
  done

  if [ -z "$stale_blocks" ] && [ -z "$migration_warnings" ]; then
    return 0
  fi

  echo ""
  echo "--- Open-Task Audit ---"
  if [ -n "$migration_warnings" ]; then
    echo "Legacy 'done/' folder(s) — migrate to canonical 'resolved/':"
    printf "%s" "$migration_warnings"
  fi
  if [ -n "$stale_blocks" ]; then
    echo "Possibly-shipped tasks (>${STALE_TASK_DAYS}d, not in checkpoint):"
    printf "%s" "$stale_blocks"
    echo "Verify each (ship via PR? status already flipped?) then update frontmatter."
  fi
}

# ── BACKLOG.md staleness audit ──────────────────────────────────────────
# Each project's BACKLOG.md is hand-curated from tasks/open/ + tasks/resolved/
# inventory. It drifts whenever a task moves between buckets without a BACKLOG
# refresh. Two cheap signals:
#   - BACKLOG mtime at least 1 day behind the most recent tasks/{open,resolved}/
#     mtime (0d gaps are noise — same-session BACKLOG edits land near task edits)
#   - distinct wikilink count in BACKLOG diverges from tasks/open/*.md count
#     (slack ±3 — banner mentions of closed-since-last-update + wikilinks to
#      umbrella sub-tasks inflate the count harmlessly)
# Visibility-only: prints which BACKLOGs look stale and how. Manual regen via
# /forge-backlog (or hand-edit) is the closure step.
BACKLOG_ROW_COUNT_SLACK=3
BACKLOG_MTIME_GAP_MIN_DAYS=1
do_backlog_audit() {
  local drift_lines=""
  local env_dir env_name proj_dir proj_name backlog

  local scan_dirs=()
  for env_dir in "$VAULT_PATH"/*/; do
    [ -d "$env_dir" ] || continue
    env_name="$(basename "$env_dir")"
    case "$env_name" in
      _shared) scan_dirs+=("$env_dir") ;;
      _*) continue ;;
      *)
        for proj_dir in "$env_dir"*/; do
          [ -d "$proj_dir" ] || continue
          scan_dirs+=("$proj_dir")
        done
        ;;
    esac
  done

  local scan_dir
  for scan_dir in "${scan_dirs[@]}"; do
    proj_dir="${scan_dir%/}"
    backlog="$proj_dir/BACKLOG.md"
    [ -f "$backlog" ] || continue

    proj_name="$(basename "$(dirname "$proj_dir")")/$(basename "$proj_dir")"
    [ "$(basename "$proj_dir")" = "_shared" ] && proj_name="_shared"

    local backlog_mtime newest_task_mtime
    backlog_mtime="$(stat -f %m "$backlog" 2>/dev/null || stat -c %Y "$backlog" 2>/dev/null || echo 0)"

    newest_task_mtime=0
    local t_dir m
    for t_dir in "$proj_dir/tasks/open" "$proj_dir/tasks/resolved" "$proj_dir/tasks/done"; do
      [ -d "$t_dir" ] || continue
      m="$(find "$t_dir" -type f -name '*.md' -exec stat -f %m {} \; 2>/dev/null | sort -rn | head -1)"
      [ -z "$m" ] && m="$(find "$t_dir" -type f -name '*.md' -exec stat -c %Y {} \; 2>/dev/null | sort -rn | head -1)"
      if [ -n "$m" ] && [ "$m" -gt "$newest_task_mtime" ]; then
        newest_task_mtime="$m"
      fi
    done

    local issues=""
    if [ "$newest_task_mtime" -gt "$backlog_mtime" ]; then
      local gap_days=$(( (newest_task_mtime - backlog_mtime) / 86400 ))
      if [ "$gap_days" -ge "$BACKLOG_MTIME_GAP_MIN_DAYS" ]; then
        issues="older than tasks/ activity (${gap_days}d gap)"
      fi
    fi

    local open_count backlog_refs
    open_count=0
    if [ -d "$proj_dir/tasks/open" ]; then
      open_count="$(find "$proj_dir/tasks/open" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    fi
    # Count wikilinks only in the ACTIVE region — everything OUTSIDE any
    # `<details>...</details>` block. The history block (per
    # [[feedback_backlog_remove_completed_rows]]) is wrapped in `<details>`
    # and accumulates wikilinks to closed tasks by design; counting those
    # blurs the active-row signal this audit cares about and flags healthy
    # BACKLOGs as "diverging".
    #
    # This mirrors the active-region extraction used by audit_open_tasks_one
    # above. Naive text-marker matches (e.g. `/Recently shipped/`) trip on
    # active rows whose description PROSE mentions "Recently shipped"
    # (the task that filed this fix is exactly such a row — meta enough
    # to bite itself).
    #
    # `|| true` — grep no-match returns 1, which `pipefail` propagates and
    # `set -e` would abort on. BACKLOGs with zero wikilinks are valid (e.g.
    # an empty starter file).
    backlog_refs="$(
      awk '
        /<details/    { in_details=1; next }
        /<\/details>/ { in_details=0; next }
        !in_details   { print }
      ' "$backlog" 2>/dev/null |
        { grep -oE '\[\[[0-9]{4}-[0-9]{2}-[0-9]{2}-[^]]+\]\]' 2>/dev/null || true; } |
        sort -u | wc -l | tr -d ' '
    )"

    if [ "$open_count" -gt 0 ] && [ "$backlog_refs" -gt 0 ]; then
      local diff
      diff=$(( open_count - backlog_refs ))
      local abs_diff="${diff#-}"
      if [ "$abs_diff" -gt "$BACKLOG_ROW_COUNT_SLACK" ]; then
        [ -n "$issues" ] && issues="${issues}; "
        issues="${issues}row count diverges (${backlog_refs} wikilinks vs ${open_count} open tasks)"
      fi
    fi

    if [ -n "$issues" ]; then
      drift_lines="${drift_lines}  - ${proj_name}: ${issues}"$'\n'
    fi
  done

  if [ -n "$drift_lines" ]; then
    echo ""
    echo "--- BACKLOG Staleness ---"
    printf "%s" "$drift_lines"
    echo "Refresh by hand or via the project's BACKLOG regen workflow."
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
    # `|| true` because `git remote get-url origin` exits 128 on a repo with
    # no `origin` set yet (brand-new project, local-only sandbox). Without it,
    # `set -euo pipefail` aborts recover before the audits run.
    remote="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"
    if [ -n "$remote" ]; then
      echo ""
      echo "--- PRs ---"
      # Extract host from remote URL — works for github.com and any GitHub
      # Enterprise instance without hardcoding hostnames. Supports both SSH
      # (git@host:org/repo.git) and HTTPS (https://host/org/repo.git) forms.
      local host repo pr_json
      host="$(echo "$remote" | sed -nE 's#^(https?://|git@)([^/:]+)[/:].*#\2#p')"
      [ -z "$host" ] && host="github.com"
      repo="$(echo "$remote" | sed "s|.*${host}[:/]||;s|\.git$||")"
      pr_json="$(GH_HOST="$host" gh pr list --author @me --repo "$repo" --state open --limit 5 --json number,title,reviewDecision 2>/dev/null)"
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

  # Drift safety net — auto-archive only catches tasks whose frontmatter already
  # says `status: resolved`. These audits surface candidates that the trigger
  # (manual frontmatter flip) missed. Visibility-only, no auto-mutation.
  # Gated to maintainer mode: in end-user mode these are vault-hygiene noise
  # that distracts from project work. The subcommands themselves remain
  # callable directly (`forge-context.sh open-task-audit`) if a user wants
  # an explicit one-off check.
  if is_maintainer_mode; then
    do_open_task_audit
    do_backlog_audit
  fi

  # Install drift — surface if Forge runtime is behind the source repo.
  do_check_install_drift

  # Statusline health — surface if statusline.sh errors at runtime, since
  # Claude Code renders nothing on non-zero exit (silent UX failure).
  do_check_statusline_health

  # Vault state — surfaces drift in the vault repo itself (not the project repo).
  # Loss of laptop = loss of all decisions/checkpoints/plans if the vault never gets pushed.
  # Header + warning wording is self-orienting (signals "your vault, not the Forge source repo")
  # so first-time users don't pattern-match "uncommitted" to "I should push to shining-cat/forge".
  #
  # Multi-repo aware: the vault can host nested `.git` directories (e.g. Vault/PRO/.git
  # mounted to a Schibsted GHEC remote, while the outer Vault/.git syncs to a personal
  # GitHub). The outer's .gitignore excludes nested-repo subtrees, so PRO drift would
  # be invisible to a naive outer-only audit. We scan one level deep under VAULT_PATH
  # for additional `.git` dirs and audit each independently; thresholds apply per-repo;
  # the drift nudge fires when ANY repo trips. Discovered 2026-05-29 — task
  # 2026-05-29-vault-audit-nested-pro-repo.
  if [ -d "$VAULT_PATH/.git" ]; then
    echo ""
    echo "--- Your vault (local history) ---"

    # Discover repos: outer + any nested .git directories one level deep.
    local vault_repos=("$VAULT_PATH")
    local nested
    for nested in "$VAULT_PATH"/*/.git; do
      [ -d "$nested" ] || continue
      vault_repos+=("$(dirname "$nested")")
    done

    local any_drift=0
    local any_no_upstream=0
    local repo
    for repo in "${vault_repos[@]}"; do
      local label has_upstream
      label="$(vault_repo_label "$repo")"
      has_upstream=0
      git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 && has_upstream=1
      [ "$has_upstream" -eq 0 ] && any_no_upstream=1

      # audit_one_vault_repo prints the status line and returns 0 on drift, 1 on clean.
      if audit_one_vault_repo "$repo" "$label" "$has_upstream"; then
        any_drift=1
      fi
    done

    if [ "$any_drift" -eq 1 ]; then
      if [ "$any_no_upstream" -eq 1 ]; then
        echo "[!] Your vault has drift — commit + push when you reach a natural pause. (Some repos have no remote — those stay on your laptop until pushed.)"
      else
        echo "[!] Your vault has drift — commit + push when you reach a natural pause."
      fi
    fi
  elif ! grep -q '^VAULT_GIT_DECLINED=true' "$HOME/.claude/forge.conf" 2>/dev/null; then
    echo ""
    echo "--- Your vault (local history) ---"
    echo "Not under version control. Decisions, checkpoints, plans live only on this disk."
    echo "Run \`git -C $VAULT_PATH init\` to enable history + recovery."
  fi

  # Personal wind-down phrases (slice 3 — prose wind-down trigger learning loop).
  # Surface the user's learned phrases on entry so Petra recognizes them as
  # canonical (no educational tip needed) throughout the session. Silent when
  # the file doesn't exist or holds an empty list.
  local wd_file="$VAULT_PATH/_shared/wind-down-phrases.json"
  if [ -f "$wd_file" ] && command -v jq >/dev/null 2>&1; then
    local wd_phrases
    wd_phrases=$(jq -r '.phrases[]?' "$wd_file" 2>/dev/null)
    if [ -n "$wd_phrases" ]; then
      echo ""
      echo "--- Personal wind-down phrases ---"
      echo "$wd_phrases" | paste -sd, - | sed 's/,/, /g'
    fi
  fi

  echo "========================"

  # Truncate breadcrumbs (fresh session)
  if [ -f "$BREADCRUMBS_FILE" ]; then
    > "$BREADCRUMBS_FILE"
  fi
}

# ── Statusline health check ───────────────────────────────────────────
# Surface "statusline script errors" at session entry so silent renders don't
# go unnoticed. Claude Code renders NOTHING when ~/.claude/statusline.sh exits
# non-zero — pure silent UX failure mode. The 2026-06-01 incident proved how
# long that can last (4 days of blackout from PR #42 smoke-test residue, found
# only when the user noticed). PR #50 closed the install-time corruption path
# for A2-preserve files; this catches RUNTIME failures from ANY cause
# (env breakage, dependency removal, downstream-script regression, etc.).
#
# Silent when OK. One block of output when the script errors. Gated on
# .statusLine being configured in settings.json — no statusline = no failure.
do_check_statusline_health() {
  local sl="$HOME/.claude/statusline.sh"
  [ -x "$sl" ] || return 0

  # Skip the probe if Claude Code isn't configured to use a statusline.
  # If .statusLine is absent, CC renders no chip and the script never runs;
  # probing it would surface false-positive warnings for users who don't
  # have a statusline.
  local settings="$HOME/.claude/settings.json"
  if [ -f "$settings" ]; then
    if ! jq -e '.statusLine' "$settings" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # Minimal mock JSON covering every field statusline.sh reads. Includes
  # .version + .session_id even though defaults handle their absence — fewer
  # branches mocked = fewer false-positive failure modes in the probe itself.
  local mock='{"model":{"display_name":"X"},"workspace":{"current_dir":"/","project_dir":"/"},"cost":{"total_cost_usd":0,"total_duration_ms":0,"total_lines_added":0,"total_lines_removed":0},"version":"0","session_id":"probe"}'

  # Capture-without-aborting: script header is `set -euo pipefail`, so a
  # non-zero exit from $sl would terminate the parent recover unless we
  # explicitly handle it. The `|| exit_code=$?` pattern matches the
  # convention used in do_check_install_drift (see `behind=$(... || echo 0)`).
  local out exit_code=0
  out=$(echo "$mock" | "$sl" 2>&1) || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo ""
    echo "--- Statusline state ---"
    echo "[!] Statusline script errored (exit $exit_code) — chip will not render in Claude Code."
    echo "    Script: $sl"
    # First few lines of stderr/stdout merge are typically the most informative
    # (e.g. bash syntax error pointer, missing-command name, jq parse error).
    if [ -n "$out" ]; then
      echo "$out" | head -3 | sed 's/^/    /'
    fi
    echo "    Fix: check the script for syntax errors / missing deps;"
    echo "         compare against source-of-truth in your Forge install dir."
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
  # Exception: `session: closed` in checkpoint frontmatter → dormant (gray), no urgency.
  # A cleanly-closed project's stale checkpoint isn't neglect; it's intentional dormancy.
  local session_state=""
  if [ -f "$CHECKPOINT_FILE" ]; then
    session_state="$(awk '/^---$/{c++; next} c==1 && /^session:/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$CHECKPOINT_FILE" 2>/dev/null)"
  fi
  local indicator
  if [ "$session_state" = "closed" ]; then
    indicator=$(printf "\033[90m💾 dormant\033[0m")
  else
    local color
    if [ "$age" -le 15 ]; then
      color='\033[32m'  # green
    elif [ "$age" -le 30 ]; then
      color='\033[33m'  # yellow
    else
      color='\033[31m'  # red
    fi
    indicator=$(printf "${color}💾 %sm ago\033[0m" "$age")
  fi

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
  forge_repo=$(grep '^FORGE_REPO=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)
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
    echo "    Update:  (cd $forge_repo && git pull && ./install.sh --interactive)"
    echo "    Preview: (cd $forge_repo && git pull && ./install.sh --preview)"
    echo "    Note: --preview splits overwrites (~) from preserved customizations (≈)."
    echo "          Locally-tuned files (statusline.sh, references) are never overwritten;"
    echo "          their upstream content is written as a <file>.upstream.<ts> sibling."
  fi
  if [ "$ahead" -gt 0 ]; then
    echo "    Local: $ahead commit(s) ahead of upstream (maintainer-side work)."
  fi
  if [ "$fetch_age_days" -ge 7 ] && [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
    echo "Last upstream fetch: $fetch_age_days days ago."
    echo "    Refresh: git -C $forge_repo fetch  (then re-run /forge to recheck)"
  fi

  # Rollback hint: if any backup artifacts exist under ~/.claude/, surface that
  # restoration is available. Only fires when drift is already being reported
  # (the early-return at the top guards the silent in-sync case), so this reads
  # as "you might want to roll back instead of/alongside updating".
  if [ -n "$(_rollback_discover)" ]; then
    echo "    Rollback available: ~/.claude/scripts/forge-context.sh rollback-install list"
  fi
}

# ── Subcommand: check-install ─────────────────────────────────────────
# Explicit "fetch + report" — call this when the user wants an active drift
# check (vs the cached check baked into do_recover). Useful as a slash-command
# target or shell alias when you've been working a while and want a fresh read.
do_check_install() {
  local forge_repo
  forge_repo=$(grep '^FORGE_REPO=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)
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

# ── Subcommand: rollback-install ────────────────────────────────────────
# User-facing entry point for consuming the backup artifacts that install.sh
# leaves behind under ~/.claude/:
#   *.pre-update.<ts>   — saved by safe_cp before overwriting (Slice 2)
#   *.pre-remove.<ts>   — saved by remove_path before deleting (Slice 2)
#   *.upstream.<ts>     — A2 preserve-policy sibling, never auto-cleaned (Slice 3)
#
# Verb surface (default = list when no verb given):
#   list             — grouped inventory of all backup artifacts
#   restore <path>   — restore a .pre-update / .pre-remove backup over its target
#   accept-upstream <path>
#                    — replace target with the .upstream sibling (A2 update opt-in)
#   clean            — prune old backups; --keep-last N (default 3) / --older-than DAYS / --dry-run
do_rollback_install() {
  local verb="${1:-list}"
  case "$verb" in
    list)            _rollback_list "${@:2}" ;;
    restore)         _rollback_restore "${@:2}" ;;
    accept-upstream) _rollback_accept_upstream "${@:2}" ;;
    clean)           _rollback_clean "${@:2}" ;;
    -h|--help|help)
      cat <<'EOF'
Usage: forge-context.sh rollback-install [verb] [args...]

Verbs:
  list                       Inventory of backup artifacts under ~/.claude/ (default)
  restore <path>             Restore a .pre-update / .pre-remove backup over its target
  accept-upstream <path>     Replace target with the .upstream sibling (A2 update opt-in)
  clean [--keep-last N]      Prune old backups (default: keep last 3 per target)
        [--older-than DAYS]  Only consider backups older than DAYS days
        [--dry-run]          Show what would be removed without removing
EOF
      ;;
    *)
      echo "rollback-install: unknown verb '$verb'" >&2
      echo "Run 'forge-context.sh rollback-install --help' for usage." >&2
      return 1
      ;;
  esac
}

_rollback_discover() {
  local home_claude="$HOME_DIR/.claude"
  [ -d "$home_claude" ] || return 0

  find "$home_claude" \
    \( -path "$home_claude/projects" -o \
       -path "$home_claude/worktrees" -o \
       -path "$home_claude/todos" -o \
       -path "$home_claude/shell-snapshots" -o \
       -path "$home_claude/statsig" -o \
       -path "$home_claude/sessions" -o \
       -path "$home_claude/file-history" -o \
       -path "$home_claude/paste-cache" -o \
       -path "$home_claude/image-cache" -o \
       -path "$home_claude/cache" \) -prune \
    -o \( -name '*.pre-update.[0-9]*-[0-9]*' -o \
          -name '*.pre-remove.[0-9]*-[0-9]*' -o \
          -name '*.upstream.[0-9]*-[0-9]*' \) \
       \( -type f -o -type l \) -print 2>/dev/null | \
  while IFS= read -r backup; do
    local base kind ts target ftype
    base="${backup##*/}"
    case "$base" in
      *.pre-update.[0-9]*-[0-9]*) kind=pre-update ;;
      *.pre-remove.[0-9]*-[0-9]*) kind=pre-remove ;;
      *.upstream.[0-9]*-[0-9]*)   kind=upstream ;;
      *) continue ;;
    esac
    ts="${backup##*.}"
    target="${backup%.${kind}.${ts}}"
    if [ -L "$backup" ]; then
      ftype=symlink
    else
      ftype=file
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$target" "$backup" "$ts" "$ftype"
  done
}

_rollback_list() {
  local home_claude="$HOME_DIR/.claude"
  local c_yellow=$'\033[33m' c_red=$'\033[31m' c_cyan=$'\033[36m' c_dim=$'\033[2m' c_off=$'\033[0m'
  local tsv
  tsv=$(_rollback_discover)
  if [ -z "$tsv" ]; then
    echo "No rollback artifacts under $home_claude."
    echo "(install.sh creates them under .pre-update.<ts> / .pre-remove.<ts> / .upstream.<ts>.)"
    return 0
  fi

  echo "Rollback artifacts under $home_claude"
  echo

  _rollback_list_kind() {
    local kind="$1" glyph="$2" color="$3" label="$4"
    local rows
    rows=$(printf '%s\n' "$tsv" | awk -F'\t' -v k="$kind" '$1==k')
    printf '%s%s%s %s — %s\n' "$color" "$glyph" "$c_off" "$kind" "$label"
    if [ -z "$rows" ]; then
      printf '  %s(none)%s\n\n' "$c_dim" "$c_off"
      return 0
    fi
    printf '%s\n' "$rows" | awk -F'\t' '
      { tgt=$2; ts=$4; ftype=$5
        count[tgt]++
        if (ts > latest[tgt]) { latest[tgt]=ts; latest_ftype[tgt]=ftype }
      }
      END {
        for (t in count) printf "%s\t%d\t%s\t%s\n", t, count[t], latest[t], latest_ftype[t]
      }' | sort | while IFS=$'\t' read -r target count latest ftype; do
      local display plural
      display="${target/#$HOME_DIR/~}"
      [ "$count" -eq 1 ] && plural="" || plural="s"
      if [ "$kind" = "upstream" ]; then
        printf '  %-58s (%d backup%s, latest %s, %s)\n' \
          "$display" "$count" "$plural" "$latest" "$ftype"
      else
        printf '  %-58s (%d backup%s, latest %s)\n' \
          "$display" "$count" "$plural" "$latest"
      fi
    done
    echo
  }

  _rollback_list_kind pre-update '~' "$c_yellow" "saved before overwriting on update"
  _rollback_list_kind pre-remove '-' "$c_red"    "saved before deletion on update"
  _rollback_list_kind upstream   '≈' "$c_cyan"   "A2 preserve siblings (drift indicators)"

  local total pu pr up plural
  total=$(printf '%s\n' "$tsv" | wc -l | tr -d ' ')
  pu=$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="pre-update"' | wc -l | tr -d ' ')
  pr=$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="pre-remove"' | wc -l | tr -d ' ')
  up=$(printf '%s\n' "$tsv" | awk -F'\t' '$1=="upstream"' | wc -l | tr -d ' ')
  [ "$total" -eq 1 ] && plural="" || plural="s"
  printf '%sTotal:%s %d backup artifact%s (%d pre-update, %d pre-remove, %d upstream)\n\n' \
    "$c_dim" "$c_off" "$total" "$plural" "$pu" "$pr" "$up"

  cat <<'EOF'
Verbs:
  Restore one:     forge-context.sh rollback-install restore <target>
  Accept update:   forge-context.sh rollback-install accept-upstream <target>
  Prune old ones:  forge-context.sh rollback-install clean [--keep-last N] [--older-than DAYS]
EOF
}

_rollback_restore() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo "rollback-install restore: missing <target> argument." >&2
    echo "Usage: forge-context.sh rollback-install restore <target>" >&2
    echo "(run 'rollback-install list' to see available targets)" >&2
    return 1
  fi

  # Normalize the target path. Accept either an absolute path or one with a
  # leading ~ that the shell didn't expand. Strip a trailing backup suffix in
  # case the user pasted a backup path by mistake — they almost certainly meant
  # the underlying target.
  case "$target" in
    '~'/*) target="$HOME_DIR/${target#'~'/}" ;;
  esac
  case "$target" in
    *.pre-update.[0-9]*-[0-9]*|*.pre-remove.[0-9]*-[0-9]*|*.upstream.[0-9]*-[0-9]*)
      local suffix="${target##*.}"
      local kind_part="${target%.*}"; kind_part="${kind_part##*.}"
      target="${target%.${kind_part}.${suffix}}"
      echo "(interpreting as target: $target)"
      ;;
  esac

  # Find latest .pre-update / .pre-remove backup for this target. (We
  # deliberately exclude .upstream — that's accept-upstream's domain.)
  local row backup kind ts
  row=$(_rollback_discover | awk -F'\t' -v t="$target" '
    ($1=="pre-update" || $1=="pre-remove") && $2==t' | sort -t $'\t' -k4 | tail -1)
  if [ -z "$row" ]; then
    echo "No .pre-update or .pre-remove backups found for: $target" >&2
    echo "(run 'rollback-install list' to see what's available; .upstream backups need accept-upstream)" >&2
    return 1
  fi
  kind=$(printf '%s\n' "$row" | awk -F'\t' '{print $1}')
  backup=$(printf '%s\n' "$row" | awk -F'\t' '{print $3}')
  ts=$(printf '%s\n' "$row" | awk -F'\t' '{print $4}')

  echo "Restoring from: $backup"
  echo "        target: $target"
  echo "        kind:   $kind (saved $ts)"
  echo

  # Show the diff between backup and current target. Three sub-cases:
  if [ -e "$target" ] || [ -L "$target" ]; then
    echo "Diff (backup → current target, up to 60 lines):"
    diff -u "$backup" "$target" 2>/dev/null | head -60 || true
    echo
  else
    echo "(target currently absent on disk — restore will re-create it)"
    echo
  fi

  # Conservative default: N. Destructive op.
  local answer
  if [ -t 0 ]; then
    printf "Apply restore? [y/N] " >/dev/tty
    read -r answer </dev/tty
  else
    echo "(non-tty: refusing to apply restore without explicit --yes — aborting)" >&2
    return 1
  fi
  case "${answer:-N}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted (no changes)."; return 0 ;;
  esac

  # Save current state before overwriting, so the rollback is itself reversible.
  if [ -e "$target" ] || [ -L "$target" ]; then
    local pre_rollback_ts
    pre_rollback_ts=$(date +%Y%m%d-%H%M%S)
    local pre_rollback="${target}.pre-rollback.${pre_rollback_ts}"
    cp -p "$target" "$pre_rollback" 2>/dev/null || cp "$target" "$pre_rollback"
    echo "Saved current state to: $pre_rollback"
  fi

  # Atomic-ish replace: write to .tmp sibling, then mv into place.
  local tmp="${target}.restore.tmp.$$"
  mkdir -p "$(dirname "$target")"
  cp -p "$backup" "$tmp" 2>/dev/null || cp "$backup" "$tmp"
  mv -f "$tmp" "$target"
  echo "Restored: $target"
}

_rollback_accept_upstream() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo "rollback-install accept-upstream: missing <target> argument." >&2
    echo "Usage: forge-context.sh rollback-install accept-upstream <target>" >&2
    echo "(run 'rollback-install list' to see available targets with ≈ markers)" >&2
    return 1
  fi

  case "$target" in
    '~'/*) target="$HOME_DIR/${target#'~'/}" ;;
  esac
  case "$target" in
    *.upstream.[0-9]*-[0-9]*)
      local suffix="${target##*.}"
      local kind_part="${target%.*}"; kind_part="${kind_part##*.}"
      target="${target%.${kind_part}.${suffix}}"
      echo "(interpreting as target: $target)"
      ;;
  esac

  local row backup ts ftype
  row=$(_rollback_discover | awk -F'\t' -v t="$target" '$1=="upstream" && $2==t' | sort -t $'\t' -k4 | tail -1)
  if [ -z "$row" ]; then
    echo "No .upstream sibling found for: $target" >&2
    echo "(only A2 preserve-policy files get .upstream siblings — see 'rollback-install list')" >&2
    return 1
  fi
  backup=$(printf '%s\n' "$row" | awk -F'\t' '{print $3}')
  ts=$(printf '%s\n' "$row" | awk -F'\t' '{print $4}')
  ftype=$(printf '%s\n' "$row" | awk -F'\t' '{print $5}')

  echo "Accept upstream from: $backup"
  echo "              target: $target"
  echo "              saved:  $ts (sibling is a $ftype)"
  echo

  # Detect drift first so we don't bother the user when there's nothing to do.
  local in_sync=0
  if [ -L "$backup" ] && [ -L "$target" ]; then
    [ "$(readlink "$backup")" = "$(readlink "$target")" ] && in_sync=1
  elif [ ! -L "$backup" ] && [ -f "$backup" ] && [ ! -L "$target" ] && [ -f "$target" ]; then
    cmp -s "$backup" "$target" && in_sync=1
  fi
  if [ "$in_sync" = "1" ]; then
    echo "Target is already in sync with upstream. Nothing to do."
    return 0
  fi

  # Show what would change, varying by file/symlink combinations.
  if [ -L "$backup" ]; then
    echo "Upstream sibling is a symlink → $(readlink "$backup")"
    if [ -L "$target" ]; then
      echo "Current target is a symlink → $(readlink "$target")"
      echo "(accept-upstream will re-point the target symlink to the upstream destination.)"
    elif [ -e "$target" ]; then
      echo "Current target is a regular file ($(wc -c <"$target" | tr -d ' ') bytes)."
      echo "(accept-upstream will replace the file with a symlink to the upstream destination.)"
    else
      echo "Current target does not exist."
      echo "(accept-upstream will create a symlink to the upstream destination.)"
    fi
  else
    if [ -L "$target" ]; then
      echo "Current target is a symlink → $(readlink "$target")"
      echo "(accept-upstream will replace the symlink with the upstream file content.)"
    elif [ -e "$target" ]; then
      echo "Diff (current target → upstream, up to 60 lines):"
      diff -u "$target" "$backup" 2>/dev/null | head -60 || true
    else
      echo "Current target does not exist. (accept-upstream will create it from upstream.)"
    fi
  fi
  echo

  local answer
  if [ -t 0 ]; then
    printf "Apply accept-upstream? [y/N] " >/dev/tty
    read -r answer </dev/tty
  else
    echo "(non-tty: refusing to apply accept-upstream without explicit --yes — aborting)" >&2
    return 1
  fi
  case "${answer:-N}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted (no changes)."; return 0 ;;
  esac

  # Save current state (file or symlink) before overwriting.
  if [ -e "$target" ] || [ -L "$target" ]; then
    local pre_rollback_ts pre_rollback
    pre_rollback_ts=$(date +%Y%m%d-%H%M%S)
    pre_rollback="${target}.pre-rollback.${pre_rollback_ts}"
    if [ -L "$target" ]; then
      cp -P "$target" "$pre_rollback"
    else
      cp -p "$target" "$pre_rollback" 2>/dev/null || cp "$target" "$pre_rollback"
    fi
    echo "Saved current state to: $pre_rollback"
  fi

  mkdir -p "$(dirname "$target")"
  if [ -L "$backup" ]; then
    local link_dst
    link_dst=$(readlink "$backup")
    rm -f "$target"
    ln -s "$link_dst" "$target"
  else
    local tmp="${target}.accept.tmp.$$"
    cp -p "$backup" "$tmp" 2>/dev/null || cp "$backup" "$tmp"
    [ -L "$target" ] && rm -f "$target"
    mv -f "$tmp" "$target"
  fi
  echo "Accepted upstream: $target"
}

_rollback_clean() {
  local keep_last=3 older_than="" dry_run=0 assume_yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-last)
        shift; keep_last="${1:-}"
        if ! [[ "$keep_last" =~ ^[0-9]+$ ]]; then
          echo "clean: --keep-last requires a non-negative integer (got: ${keep_last:-<missing>})" >&2
          return 1
        fi
        if [ "$keep_last" -eq 0 ]; then
          echo "clean: refusing --keep-last 0 (would delete ALL backups including the most recent)." >&2
          echo "If that's really what you want, delete them manually with find(1)." >&2
          return 1
        fi
        ;;
      --older-than)
        shift; older_than="${1:-}"
        if ! [[ "$older_than" =~ ^[0-9]+$ ]] || [ "$older_than" -lt 1 ]; then
          echo "clean: --older-than requires a positive integer (days) (got: ${older_than:-<missing>})" >&2
          return 1
        fi
        ;;
      --dry-run) dry_run=1 ;;
      --yes|-y) assume_yes=1 ;;
      -h|--help|help)
        cat <<'EOF'
Usage: forge-context.sh rollback-install clean [options]

Options:
  --keep-last N      Keep the N newest backups per (kind, target). Default: 3.
                     N=0 is refused (would wipe everything).
  --older-than DAYS  Only delete backups older than DAYS days (combine with --keep-last
                     to keep recent ones regardless of age).
  --dry-run          Show what would be deleted, but make no changes.
  --yes, -y          Skip the interactive prompt (required for non-tty use).

By default, ALL backup kinds (.pre-update, .pre-remove, .upstream) are eligible
for pruning. The keep-last default of 3 is conservative enough to preserve at
least one .upstream sibling per A2 target in normal use.
EOF
        return 0
        ;;
      *)
        echo "clean: unknown argument '$1'" >&2
        echo "(run 'rollback-install clean --help' for usage)" >&2
        return 1
        ;;
    esac
    shift
  done

  local tsv
  tsv=$(_rollback_discover)
  if [ -z "$tsv" ]; then
    echo "No rollback artifacts to clean."
    return 0
  fi

  local cutoff=""
  if [ -n "$older_than" ]; then
    cutoff=$(date -v-"${older_than}"d +%Y%m%d-%H%M%S 2>/dev/null \
             || date -d "${older_than} days ago" +%Y%m%d-%H%M%S 2>/dev/null \
             || echo "")
    if [ -z "$cutoff" ]; then
      echo "clean: could not compute cutoff date (date(1) compatibility)" >&2
      return 1
    fi
  fi

  local delete_list
  delete_list=$(printf '%s\n' "$tsv" | sort -t $'\t' -k1,1 -k2,2 -k4,4r | awk -F'\t' -v keep="$keep_last" -v cutoff="$cutoff" '
    {
      key = $1 "\t" $2
      seen[key]++
      if (seen[key] <= keep) next
      if (cutoff != "" && $4 >= cutoff) next
      print $0
    }')

  if [ -z "$delete_list" ]; then
    echo "Nothing to clean — all backups within keep-last=$keep_last${older_than:+ and newer than $older_than days}."
    return 0
  fi

  local count
  count=$(printf '%s\n' "$delete_list" | wc -l | tr -d ' ')

  if [ "$dry_run" = "1" ]; then
    echo "Dry-run — would delete $count backup file(s):"
  else
    echo "Will delete $count backup file(s):"
  fi
  printf '%s\n' "$delete_list" | awk -F'\t' -v home="$HOME_DIR" '
    { d=$3; sub("^" home, "~", d); printf "  %s (%s)\n", d, $1 }'
  echo

  if [ "$dry_run" = "1" ]; then
    echo "(dry-run — no changes made; rerun without --dry-run to apply)"
    return 0
  fi

  if [ "$assume_yes" = "1" ]; then
    :  # skip prompt
  elif [ -t 0 ]; then
    local answer
    printf "Delete these %d file(s)? [y/N] " "$count" >/dev/tty
    read -r answer </dev/tty
    case "${answer:-N}" in
      y|Y|yes|YES) ;;
      *) echo "Aborted (no changes)."; return 0 ;;
    esac
  else
    echo "(non-tty: refusing to delete without explicit --yes — aborting)" >&2
    return 1
  fi

  local deleted=0 failed=0
  while IFS=$'\t' read -r kind target backup ts ftype; do
    if rm -f "$backup" 2>/dev/null; then
      deleted=$((deleted + 1))
    else
      failed=$((failed + 1))
      echo "  [!] failed to delete: $backup" >&2
    fi
  done <<EOF
$delete_list
EOF
  echo "Deleted: $deleted / $count"
  [ "$failed" -gt 0 ] && return 1
  return 0
}

# ── Subcommand: wrap-up-state ─────────────────────────────────────────
# Returns Petra's wrap-up signal as one of:
#   too_early    — session < WRAP_UP_TOO_EARLY_MIN; suppress wrap-up suggestions
#   eod_window   — within WRAP_UP_EOD_WINDOW_MIN of preferred_end_of_day; PROACTIVELY nudge
#   past_eod     — past preferred_end_of_day; nudge harder
#   eow_window   — same as eod_window, but on EOW_DAY (Friday by default); ALSO trigger weekly-wrap
#   past_eow     — same as past_eod, but on EOW_DAY; ALSO trigger weekly-wrap
#   mid_session  — neither extreme; no nudge either way
#   unknown      — no marker, no preferred_end_of_day, or stat failed; default to silent
#
# The EOW states are strictly stronger than their EOD counterparts: callers
# that only care about end-of-day behavior can treat eow_window like eod_window
# (and past_eow like past_eod). Callers wanting weekly-wrap behavior dispatch
# on the eow_* variants specifically.
#
# Reads:
#   - $MARKER mtime as session-age proxy (when /forge entered)
#   - $VAULT_PATH/_shared/wellness-preferences.json for preferred_end_of_day (HH:MM)
#   - $EOW_DAY (loaded from forge.conf at startup, defaults to 5 = Friday)
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

  # Compute base eod state, then upgrade to eow on EOW_DAY.
  local base_state today_dow
  if [ "$minutes_to_eod" -le 0 ]; then
    base_state="past_eod"
  elif [ "$minutes_to_eod" -le "$WRAP_UP_EOD_WINDOW_MIN" ]; then
    base_state="eod_window"
  else
    echo "mid_session"
    return 0
  fi

  today_dow=$(date +%u 2>/dev/null)
  if [ "$today_dow" = "$EOW_DAY" ]; then
    case "$base_state" in
      eod_window) echo "eow_window" ;;
      past_eod)   echo "past_eow" ;;
    esac
  else
    echo "$base_state"
  fi
}

# ── Subcommand: weekly-wrap-due ───────────────────────────────────────
# Print `due` if the weekly wrap hasn't run within FORGE_WEEKLY_WRAP_GAP_DAYS,
# else `not-due`. Read from $VAULT_PATH/_shared/forge-runtime.json. Missing or
# malformed file → `due` (treat as "never run"). Exit 0 either way.
#
# Used by:
#   - forge SKILL.md Step 6 entry summary (conditionally render "Weekly wrap: due")
#   - forge-exit SKILL.md Notes (suggest /forge-weekly on Friday exit)
#   - forge-weekly SKILL.md Step 0 idempotency guard
FORGE_RUNTIME_FILE="$VAULT_PATH/_shared/forge-runtime.json"

do_weekly_wrap_due() {
  if [ ! -f "$FORGE_RUNTIME_FILE" ]; then
    echo "due"
    return 0
  fi
  local last_ts last_epoch now_epoch age_days
  last_ts=$(jq -r '.last_weekly_wrap_timestamp // empty' "$FORGE_RUNTIME_FILE" 2>/dev/null)
  if [ -z "$last_ts" ] || [ "$last_ts" = "null" ]; then
    echo "due"
    return 0
  fi
  # Parse ISO8601 timestamp. Try BSD date first (macOS), then GNU date.
  last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$last_ts" "+%s" 2>/dev/null \
            || date -d "$last_ts" "+%s" 2>/dev/null \
            || echo "")
  if [ -z "$last_epoch" ]; then
    # Malformed timestamp — treat as never run, force re-wrap
    echo "due"
    return 0
  fi
  now_epoch=$(date +%s)
  age_days=$(( (now_epoch - last_epoch) / 86400 ))
  if [ "$age_days" -ge "$FORGE_WEEKLY_WRAP_GAP_DAYS" ]; then
    echo "due"
  else
    echo "not-due"
  fi
}

# ── Subcommand: mark-weekly-wrap-done ─────────────────────────────────
# Write last_weekly_wrap_timestamp=now + last_weekly_wrap_week=YYYY-WNN to
# $VAULT_PATH/_shared/forge-runtime.json. Creates the file if missing.
# Idempotent — re-running just overwrites with current timestamp.
#
# Called by forge-weekly SKILL.md Step 5 once the ceremony has completed.
do_mark_weekly_wrap_done() {
  local now_ts iso_week
  now_ts=$(date "+%Y-%m-%dT%H:%M:%S")
  # ISO 8601 week (YYYY-WNN). Both BSD and GNU date support %G-W%V.
  iso_week=$(date "+%G-W%V")

  if [ ! -f "$FORGE_RUNTIME_FILE" ]; then
    # Lazy-create with just the keys we care about
    printf '{\n  "last_weekly_wrap_timestamp": "%s",\n  "last_weekly_wrap_week": "%s"\n}\n' \
      "$now_ts" "$iso_week" > "$FORGE_RUNTIME_FILE"
    echo "marked: $now_ts ($iso_week)"
    return 0
  fi

  # Merge into existing file — preserve any other keys other tooling may add.
  local tmp
  tmp=$(mktemp)
  jq --arg ts "$now_ts" --arg wk "$iso_week" \
     '.last_weekly_wrap_timestamp = $ts | .last_weekly_wrap_week = $wk' \
     "$FORGE_RUNTIME_FILE" > "$tmp" && mv "$tmp" "$FORGE_RUNTIME_FILE"
  echo "marked: $now_ts ($iso_week)"
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
      _shared)    suggested_msg="shared: update shared/cross-cutting vault state" ;;
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

# ── Helper: flip `session: closed` → `session: open` in checkpoint frontmatter ──
# Idempotent — no-op if file missing, `session:` line absent, or value already
# anything other than "closed". Mutates only the first `session:` line inside
# the first frontmatter block (--- ... ---), never the body.
#
# Why: `/forge-exit` writes `session: closed` so the statusline can render
# `💾 dormant` for cleanly-closed projects. But on re-entry that flag persists
# until the next checkpoint write, leaving statusline misleadingly "dormant"
# during an actively-resumed session. Flipping at marker-activation time fixes
# the visual mismatch immediately. (See 2026-06-03 forge checkpoint Progress
# note — the bug surfaced when statusline showed dormant for hours of active
# work after re-entering on `forge` project.)
flip_session_to_open() {
  local checkpoint_path="$1"
  [ -f "$checkpoint_path" ] || return 0
  awk '
    BEGIN { c = 0; flipped = 0 }
    /^---$/ { c++ }
    c == 1 && flipped == 0 && /^session:[[:space:]]*closed[[:space:]]*$/ {
      sub(/closed/, "open")
      flipped = 1
    }
    { print }
  ' "$checkpoint_path" > "${checkpoint_path}.tmp" && mv "${checkpoint_path}.tmp" "$checkpoint_path"
}

# ── Subcommand: set-marker (write the forge-active marker file) ─────────
# Replaces direct Write-tool calls from Claude during session entry/exit.
# Routing through this script avoids Claude Code's overwrite-confirmation
# prompt that fires on every Write to an existing file (separate from the
# permission allowlist). This script is fully allowlisted as
# Bash(~/.claude/scripts/forge-context.sh *), so the marker write completes
# silently.
#
# Forms:
#   set-marker pending           → writes the literal sentinel "__pending__"
#                                  (step 1b of /forge entry, before project chosen)
#   set-marker active <project>  → writes a JSON marker with session_id,
#                                  project, started_at, tmux_pane
#                                  (step 1c, after project disambiguated)
#                                  AND flips the project checkpoint's frontmatter
#                                  `session: closed` → `session: open` if needed
#                                  so statusline doesn't render dormant on resume.
#   set-marker clear             → empties the marker (used by /forge-exit)
do_set_marker() {
  local form="${1:-}"
  case "$form" in
    pending)
      printf '%s' '__pending__' > "$MARKER"
      ;;
    active)
      local project="${2:-}"
      if [ -z "$project" ]; then
        echo "[forge-context] set-marker active requires <project> arg" >&2
        exit 1
      fi
      local session="${CLAUDE_CODE_SESSION_ID:-}"
      local started
      started="$(date +'%Y-%m-%dT%H:%M:%S%z')"
      local tmux_pane_json="null"
      if [ -n "${TMUX_PANE:-}" ]; then
        tmux_pane_json="\"$TMUX_PANE\""
      fi
      printf '{"session_id":"%s","project":"%s","started_at":"%s","tmux_pane":%s}' \
        "$session" "$project" "$started" "$tmux_pane_json" > "$MARKER"
      # Flip the project checkpoint's session flag so statusline reflects active
      # state immediately (avoids stale `💾 dormant` indicator on session resume).
      local project_vault_dir
      project_vault_dir="$(get_vault_dir "$project" 2>/dev/null)"
      if [ -n "$project_vault_dir" ]; then
        flip_session_to_open "$project_vault_dir/current-checkpoint.md"
      fi
      ;;
    clear)
      : > "$MARKER"
      ;;
    *)
      echo "Usage: forge-context.sh set-marker {pending|active <project>|clear}" >&2
      exit 1
      ;;
  esac
}

# ── Subcommand: append-braindump (append entry to active braindump) ─────
# Replaces `cat >> braindump.md <<EOF ... EOF` heredoc patterns from Claude.
# Same prompt-bypass rationale as set-marker: this script is fully allowlisted;
# the heredoc form is not (and adds compound-command risk with trailing `echo`).
#
# Arg: single positional string (multi-line allowed via embedded newlines).
# Prepends a blank line for entry separation, ensures trailing newline.
do_append_braindump() {
  local content="${1:-}"
  if [ -z "$content" ]; then
    echo "[forge-context] append-braindump requires <content> arg" >&2
    exit 1
  fi
  if [ ! -f "$BRAINDUMP_FILE" ]; then
    : > "$BRAINDUMP_FILE"
  fi
  printf '\n%s\n' "$content" >> "$BRAINDUMP_FILE"
}

# ── Subcommand: append-friction (structured friction-log entry + JSON index) ──
# Writes to both friction-log.md (human-readable) and friction-classified.json
# (machine-readable). Validates --pattern against catalog; on invalid pattern,
# falls back to pattern=unknown + validation_failed=true tag, writes anyway,
# returns non-zero exit.
#
# Auto-creates stub task at --action-ref when --recurrence == 1.
#
# Args (all required unless noted):
#   --date YYYY-MM-DD
#   --description "..."
#   --pattern <slug-from-catalog|needs_new_pattern>
#   --recurrence <N>
#   --action-ref "tasks/open/<slug>.md|needs_new_pattern"
do_friction_tail() {
  # Print the N most recent entries of friction-log.md, sorted by date in
  # the H2 header. Default mode is --headline: one line per entry
  # ("<date>  <title>"), which is what session-entry priming needs.
  # --full prints the entire entry body (the legacy behavior) — opt into
  # this only when investigating a specific recent friction event.
  #
  # Sort-by-date (not by file position) because the file has historically
  # been a mix of prepended and appended entries; "last 5 by position"
  # returned a mix of old and new entries. Date is the right semantic.
  #
  # Pinned entries (those with `- **Pinned:** true` bullet) are filtered
  # out by default — they are canonical references kept for grep, not
  # routine recent-friction signal. Pass --include-pinned to see them.
  local n=5 mode="headline" include_pinned=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --headline)       mode="headline"; shift ;;
      --full)           mode="full"; shift ;;
      --include-pinned) include_pinned=true; shift ;;
      [0-9]*)           n="$1"; shift ;;
      *) echo "[friction-tail] unknown arg: $1" >&2; return 2 ;;
    esac
  done
  local file="$VAULT_PATH/_shared/friction-log.md"
  [ -f "$file" ] || return 0
  python3 - "$file" "$n" "$mode" "$include_pinned" <<'PYEOF'
import re, sys
path, n, mode, include_pinned_str = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
include_pinned = include_pinned_str == "true"
with open(path) as f:
    text = f.read()
parts = re.split(r'(?=^#{2,3} )', text, flags=re.MULTILINE)
entries = [p for p in parts if re.match(r'^#{2,3} ', p)]
def is_pinned(entry_text):
    return bool(re.search(r'^\s*-\s+\*\*Pinned:\*\*\s+true\b',
                          entry_text, re.MULTILINE | re.IGNORECASE))
if not include_pinned:
    entries = [e for e in entries if not is_pinned(e)]
def date_key(e):
    m = re.search(r'(\d{4}-\d{2}-\d{2})', e)
    return m.group(1) if m else '0000-00-00'
entries.sort(key=date_key)
last = entries[-n:]
if mode == "full":
    sys.stdout.write(''.join(last).rstrip() + '\n')
else:
    for e in last:
        head = e.splitlines()[0]
        head = re.sub(r'^#{2,3}\s+', '', head)
        print(head)
PYEOF
}

do_append_friction() {
  local date_arg="" desc="" pattern="" recurrence="" action_ref="" pinned=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --date)         date_arg="$2"; shift 2 ;;
      --description)  desc="$2"; shift 2 ;;
      --pattern)      pattern="$2"; shift 2 ;;
      --recurrence)   recurrence="$2"; shift 2 ;;
      --action-ref)   action_ref="$2"; shift 2 ;;
      --pinned)       pinned=true; shift ;;
      *) echo "[append-friction] unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  for v in date_arg desc pattern recurrence action_ref; do
    if [ -z "${!v}" ]; then
      echo "[append-friction] missing required arg: --${v//_/-}" >&2
      exit 2
    fi
  done

  # Validate pattern against catalog (or accept escape value)
  local validation_failed=false
  local original_pattern="$pattern"
  if [ "$pattern" != "needs_new_pattern" ] && [ "$pattern" != "unknown" ]; then
    if [ ! -f "$FORGE_PATTERN_CATALOG" ]; then
      echo "[append-friction] WARN: catalog not found at $FORGE_PATTERN_CATALOG; accepting pattern unchecked" >&2
    else
      if ! grep -qE "^## ${pattern}\$" "$FORGE_PATTERN_CATALOG"; then
        echo "[append-friction] FAIL: pattern '$pattern' not in catalog; falling back to 'unknown'" >&2
        validation_failed=true
        pattern="unknown"
      fi
    fi
  fi

  # Ensure files exist
  mkdir -p "$(dirname "$FRICTION_LOG")"
  [ -f "$FRICTION_LOG" ] || : > "$FRICTION_LOG"
  if [ ! -f "$FRICTION_CLASSIFIED" ]; then
    echo '{"entries":[]}' > "$FRICTION_CLASSIFIED"
  fi

  # Append to friction-log.md (human-readable)
  {
    printf '\n### %s — %s\n' "$date_arg" "$desc"
    printf -- '- **Pattern:** %s\n' "$pattern"
    printf -- '- **Recurrence:** %s\n' "$recurrence"
    printf -- '- **Action:** %s\n' "$action_ref"
    if [ "$pinned" = "true" ]; then
      printf -- '- **Pinned:** true\n'
    fi
    if [ "$validation_failed" = "true" ]; then
      printf -- '- **Validation:** failed (original pattern: %s)\n' "$original_pattern"
    fi
  } >> "$FRICTION_LOG"

  # Append to friction-classified.json (machine-readable)
  tmp_json=$(mktemp)
  jq -c --arg d "$date_arg" \
     --arg desc "$desc" \
     --arg p "$pattern" \
     --arg op "$original_pattern" \
     --argjson r "$recurrence" \
     --arg a "$action_ref" \
     --argjson vf "$validation_failed" \
     --argjson pin "$pinned" \
     '.entries += [{
        date: $d,
        description: $desc,
        pattern: $p,
        recurrence: $r,
        action_ref: $a,
        validation_failed: $vf,
        original_pattern: $op,
        pinned: $pin
     }]' "$FRICTION_CLASSIFIED" > "$tmp_json"
  mv "$tmp_json" "$FRICTION_CLASSIFIED"

  # Auto-create stub task if recurrence == 1 and action-ref is a real path
  if [ "$recurrence" = "1" ] && [ "$action_ref" != "needs_new_pattern" ]; then
    # Auto-prefix relative tasks/ paths. Prefer the active Forge project subtree
    # so friction events stay with their project (e.g., forge-on-forge friction
    # lands in PERSO/forge/tasks/, not _shared/tasks/). Fall back to _shared/
    # when no marker is active or project→ENV can't be resolved — that path
    # works for users who don't run forge-on-forge.
    local resolved_ref="$action_ref"
    if [[ "$action_ref" == tasks/* ]]; then
      local marker_project marker_env
      marker_project=$(extract_marker_project)
      marker_env=""
      [ -n "$marker_project" ] && marker_env=$(extract_marker_env "$marker_project")
      if [ -n "$marker_project" ] && [ -n "$marker_env" ]; then
        resolved_ref="$marker_env/$marker_project/$action_ref"
      else
        resolved_ref="_shared/$action_ref"
      fi
    fi
    local stub_path="$VAULT_PATH/$resolved_ref"
    if [ ! -f "$stub_path" ]; then
      mkdir -p "$(dirname "$stub_path")"
      cat > "$stub_path" <<EOF
---
created: $date_arg
updated: $date_arg
project: forge
type: task
status: needs-triage
tags: [friction-stub, $pattern]
---

# $desc

## What / Why

Auto-created from friction-log entry. Classified as **$pattern**. See [[script-replacement-patterns]] for pattern details and [[friction-classifier]] for the routing logic.

**Original friction:** $desc

## Plan

(triage required — flesh out the fix per the pattern's How-it-works)

## Progress

## Resolution
EOF
    fi
  fi

  # Exit code: non-zero if validation failed (write-then-flag)
  if [ "$validation_failed" = "true" ]; then
    exit 1
  fi
}

# ── Subcommand: pin-friction ──────────────────────────────────────────
# Mark an existing friction entry as pinned: it stays out of friction-tail's
# default output and survives harvest archival. Useful for canonical
# references cited by ongoing work (e.g. design rationale entries).
#
# Args:
#   --entry "<YYYY-MM-DD>|<description-prefix>"   match by (date, prefix)
#
# Updates both surfaces in lockstep:
#   1. friction-log.md — inserts `- **Pinned:** true` bullet right after the
#      H2/H3 heading line, if not already present
#   2. friction-classified.json — sets pinned: true on the matching entry
#
# Idempotent: pinning an already-pinned entry is a no-op (no duplicate bullet,
# no JSON change). Exit 0 on success, 1 if no entry matched.
do_pin_friction() {
  local entry_spec=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --entry) entry_spec="$2"; shift 2 ;;
      *) echo "[pin-friction] unknown arg: $1" >&2; return 2 ;;
    esac
  done
  if [ -z "$entry_spec" ]; then
    echo "[pin-friction] missing required arg: --entry \"<date>|<desc-prefix>\"" >&2
    return 2
  fi
  local date_part="${entry_spec%%|*}"
  local prefix_part="${entry_spec#*|}"
  if [ "$date_part" = "$entry_spec" ] || [ -z "$prefix_part" ]; then
    echo "[pin-friction] --entry must be \"<date>|<desc-prefix>\"" >&2
    return 2
  fi
  if [ ! -f "$FRICTION_LOG" ]; then
    echo "[pin-friction] friction-log not found at $FRICTION_LOG" >&2
    return 1
  fi

  # Edit markdown + JSON in one python pass so the match logic is shared.
  python3 - "$FRICTION_LOG" "$FRICTION_CLASSIFIED" "$date_part" "$prefix_part" <<'PYEOF'
import json, re, sys
md_path, json_path, date, prefix = sys.argv[1:5]

with open(md_path) as f:
    text = f.read()
parts = re.split(r'(?=^#{2,3} )', text, flags=re.MULTILINE)
matched_md = False
new_parts = []
for p in parts:
    head_match = re.match(r'^(#{2,3})\s+(\S+)\s+[—-]\s+(.+?)\n', p)
    if head_match and head_match.group(2) == date and head_match.group(3).startswith(prefix):
        if re.search(r'^\s*-\s+\*\*Pinned:\*\*\s+true\b', p, re.MULTILINE | re.IGNORECASE):
            new_parts.append(p)
            matched_md = True
            continue
        lines = p.split('\n', 1)
        heading = lines[0]
        rest = lines[1] if len(lines) > 1 else ''
        new_parts.append(heading + '\n- **Pinned:** true\n' + rest)
        matched_md = True
    else:
        new_parts.append(p)
if matched_md:
    with open(md_path, 'w') as f:
        f.write(''.join(new_parts))

matched_json = False
if json_path and __import__('os').path.exists(json_path):
    with open(json_path) as f:
        data = json.load(f)
    for entry in data.get('entries', []):
        if entry.get('date') == date and entry.get('description', '').startswith(prefix):
            if entry.get('pinned') is not True:
                entry['pinned'] = True
            matched_json = True
    if matched_json:
        with open(json_path, 'w') as f:
            json.dump(data, f, separators=(',', ':'))

if not matched_md and not matched_json:
    print(f"[pin-friction] no entry matched date={date} prefix={prefix!r}", file=sys.stderr)
    sys.exit(1)
if not matched_md:
    print(f"[pin-friction] WARN: JSON updated but no markdown entry matched date={date} prefix={prefix!r}", file=sys.stderr)
if not matched_json:
    print(f"[pin-friction] WARN: markdown updated but no JSON entry matched date={date} prefix={prefix!r}", file=sys.stderr)
PYEOF
}

# ── Subcommand: archive-friction-entries ─────────────────────────────
# Move matched friction-log entries to per-ISO-week archive files. Pure
# mechanics — does NOT prompt or propose; callers (harvest-friction,
# bootstrap-harvest) decide WHICH entries to archive.
#
# Args:
#   --entry "<YYYY-MM-DD>|<description-prefix>"  (repeatable)
#
# Or read entries from stdin, one "<date>|<prefix>" per line.
#
# Updates both surfaces in lockstep:
#   1. friction-log.md — removes matched entry blocks; trailing `---` separators
#      collapsed so we don't leave double-divider artifacts
#   2. friction-log-archive/YYYY-W<ISO-week>.md — appended (created on first
#      entry for a given week). Routed per-entry by the entry's own date.
#   3. friction-classified.json — sets archived_in: "YYYY-WNN" on matched
#      entries (kept for pattern analytics; we don't delete from JSON)
#
# Idempotent: an entry already archived (archived_in set in JSON, or already
# absent from friction-log.md) is a no-op. Exit 0 = success even if some
# entries didn't match (logged to stderr). Exit non-zero only on hard errors.
#
# Pinned entries are NEVER archived even if requested. Caller's responsibility
# to filter, but we also guard here as defense-in-depth.
do_archive_friction_entries() {
  local entries=()
  local from_stdin=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --entry) entries+=("$2"); shift 2 ;;
      --from-stdin) from_stdin=true; shift ;;
      *) echo "[archive-friction-entries] unknown arg: $1" >&2; return 2 ;;
    esac
  done
  # Read entries from stdin only when explicitly requested (avoids hanging
  # in non-TTY contexts like Claude Code's bash tool, which never closes stdin)
  if [ "$from_stdin" = "true" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && entries+=("$line")
    done
  fi
  if [ ${#entries[@]} -eq 0 ]; then
    echo "[archive-friction-entries] no entries specified (use --entry or --from-stdin)" >&2
    return 2
  fi
  if [ ! -f "$FRICTION_LOG" ]; then
    echo "[archive-friction-entries] friction-log not found at $FRICTION_LOG" >&2
    return 1
  fi
  local archive_dir="$VAULT_PATH/_shared/friction-log-archive"
  mkdir -p "$archive_dir"

  # Hand the work to python — needs heading parsing, ISO-week calc, json edit.
  # Entry specs come via argv (not stdin) because `python3 -` consumes stdin
  # for the script itself, which would silently swallow piped entries.
  python3 - "$FRICTION_LOG" "$FRICTION_CLASSIFIED" "$archive_dir" "${entries[@]}" <<'PYEOF'
import datetime, json, os, re, sys
md_path, json_path, archive_dir = sys.argv[1:4]
specs = []
for arg in sys.argv[4:]:
    if not arg or '|' not in arg:
        continue
    date, prefix = arg.split('|', 1)
    specs.append((date, prefix))

def iso_week_tag(date_str):
    y, m, d = (int(x) for x in date_str.split('-'))
    iso_year, iso_week, _ = datetime.date(y, m, d).isocalendar()
    return f"{iso_year}-W{iso_week:02d}"

with open(md_path) as f:
    text = f.read()
parts = re.split(r'(?=^#{2,3} )', text, flags=re.MULTILINE)
# parts[0] is the preamble (title + intro) before any heading; preserve.
preamble = parts[0] if parts and not re.match(r'^#{2,3} ', parts[0]) else ''
entry_parts = [p for p in parts if re.match(r'^#{2,3} ', p)]

def is_pinned(entry_text):
    return bool(re.search(r'^\s*-\s+\*\*Pinned:\*\*\s+true\b',
                          entry_text, re.MULTILINE | re.IGNORECASE))

def entry_key(p):
    m = re.match(r'^#{2,3}\s+(\S+)\s+[—-]\s+(.+?)\n', p)
    return (m.group(1), m.group(2)) if m else (None, None)

matched_indices = set()
archived_by_week = {}  # week_tag -> [entry_text]
for i, p in enumerate(entry_parts):
    date, title = entry_key(p)
    if not date:
        continue
    for spec_date, spec_prefix in specs:
        if date == spec_date and title.startswith(spec_prefix):
            if is_pinned(p):
                print(f"[archive-friction-entries] skip pinned: {date} {title[:40]!r}", file=sys.stderr)
                continue
            tag = iso_week_tag(date)
            archived_by_week.setdefault(tag, []).append(p.rstrip() + '\n')
            matched_indices.add(i)
            break

if not matched_indices:
    print("[archive-friction-entries] no entries matched (idempotent no-op)", file=sys.stderr)
else:
    # Rewrite friction-log.md without matched entries.
    kept = [p for i, p in enumerate(entry_parts) if i not in matched_indices]
    # Each entry block already contains its leading separator if any; re-stitch
    # with the original preamble. Collapse runs of `---\n---` introduced if a
    # removed entry sat between two separators in the source.
    new_text = preamble + ''.join(kept)
    new_text = re.sub(r'(?:\n---\n){2,}', '\n---\n', new_text)
    new_text = new_text.rstrip() + '\n'
    with open(md_path, 'w') as f:
        f.write(new_text)
    # Append each entry to its week's archive file.
    for week_tag, blocks in archived_by_week.items():
        archive_path = os.path.join(archive_dir, f"{week_tag}.md")
        is_new = not os.path.exists(archive_path)
        with open(archive_path, 'a') as f:
            if is_new:
                f.write(f"# Friction Archive — {week_tag}\n\n")
                f.write("Entries harvested and archived from `friction-log.md`. Searchable on demand; not read by recovery.\n\n---\n")
            for block in blocks:
                f.write('\n' + block)
                if not block.endswith('---\n'):
                    f.write('\n---\n')
    print(f"[archive-friction-entries] archived {len(matched_indices)} entries across {len(archived_by_week)} week(s)", file=sys.stderr)

# Update JSON: set archived_in on matched entries.
if os.path.exists(json_path):
    with open(json_path) as f:
        data = json.load(f)
    json_updates = 0
    for entry in data.get('entries', []):
        ed = entry.get('date', '')
        edesc = entry.get('description_prefix', entry.get('description', ''))
        for spec_date, spec_prefix in specs:
            if ed == spec_date and edesc.startswith(spec_prefix):
                if entry.get('pinned') is True:
                    continue
                if 'archived_in' in entry:
                    continue  # idempotent
                entry['archived_in'] = iso_week_tag(ed)
                json_updates += 1
                break
    if json_updates:
        with open(json_path, 'w') as f:
            json.dump(data, f, separators=(',', ':'))
        print(f"[archive-friction-entries] marked {json_updates} JSON entries with archived_in", file=sys.stderr)
PYEOF
}

# ── Subcommand: harvest-friction ──────────────────────────────────────
# Output JSON proposals for promoting/archiving friction entries.
#
# Reads FRICTION_CLASSIFIED, filters to: not pinned, not already archived,
# date within --days N window (default 30). Applies the heuristic from
# B-friction-log-lifecycle.md to propose a target per entry.
#
# Flags:
#   --days N    look back window in days (default 30)
#   --pretty    pretty-print the JSON output
#
# Output: JSON array of proposals (or empty `[]` if none).
# Each proposal: {entry_id, date, description, pattern, recurrence,
#                 action_ref, proposed_target, justification}
#
# entry_id format: "YYYY-MM-DD|<first-40-chars-of-description>"
# (matches the format consumed by archive-friction-entries --entry)
do_harvest_friction() {
  local days=30
  local pretty=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --days)   days="$2"; shift 2 ;;
      --pretty) pretty=true; shift ;;
      *) echo "[harvest-friction] unknown arg: $1" >&2; return 2 ;;
    esac
  done
  if [ ! -f "$FRICTION_CLASSIFIED" ]; then
    echo "[harvest-friction] no friction-classified.json at $FRICTION_CLASSIFIED" >&2
    echo "[]"; return 0
  fi
  python3 - "$FRICTION_CLASSIFIED" "$VAULT_PATH" "$days" "$pretty" <<'PYEOF'
import datetime, json, os, sys
classified_path, vault_path, days_str, pretty_str = sys.argv[1:5]
days = int(days_str)
pretty = pretty_str == "true"
today = datetime.date.today()
cutoff = today - datetime.timedelta(days=days)

with open(classified_path) as f:
    data = json.load(f)

UNCLASSIFIED = {"needs_new_pattern", "", None}

def classify(entry):
    action_ref = entry.get('action_ref')
    recurrence = entry.get('recurrence', 1)
    entry_date_str = entry.get('date', '')
    try:
        entry_date = datetime.date.fromisoformat(entry_date_str)
    except ValueError:
        return ("archive-only", "malformed date — informational only")

    if action_ref not in UNCLASSIFIED:
        # action_ref looks like a path (vault-relative); check existence
        ref_path = os.path.join(vault_path, action_ref)
        if os.path.exists(ref_path):
            return ("archive-only", f"already promoted to {action_ref}")
        else:
            return ("task", f"action_ref={action_ref} missing — rewrite")

    if recurrence >= 2:
        return ("task", f"pattern recurring (n={recurrence}) — structural fix needed")

    age_days = (today - entry_date).days
    if age_days < 14:
        return ("task", "recent + unclassified — likely needs new pattern")

    return ("archive-only", "old + unclassified — informational only")

proposals = []
for entry in data.get('entries', []):
    if entry.get('pinned') is True:
        continue
    if 'archived_in' in entry and entry.get('archived_in'):
        continue
    entry_date_str = entry.get('date', '')
    try:
        entry_date = datetime.date.fromisoformat(entry_date_str)
    except ValueError:
        continue
    if entry_date < cutoff:
        continue

    desc = entry.get('description', '')
    desc_prefix = desc[:40]
    target, justification = classify(entry)
    proposals.append({
        "entry_id": f"{entry_date_str}|{desc_prefix}",
        "date": entry_date_str,
        "description": desc,
        "pattern": entry.get('pattern', ''),
        "recurrence": entry.get('recurrence', 1),
        "action_ref": entry.get('action_ref', ''),
        "proposed_target": target,
        "justification": justification,
    })

# Sort: tasks first (more urgent), then by date desc within each group
proposals.sort(key=lambda p: (p['proposed_target'] != 'task', p['date']), reverse=False)
proposals.sort(key=lambda p: (p['proposed_target'] != 'task', -int(p['date'].replace('-', ''))))

if pretty:
    print(json.dumps(proposals, indent=2, ensure_ascii=False))
else:
    print(json.dumps(proposals, separators=(',', ':'), ensure_ascii=False))
PYEOF
}

# ── Subcommand: promote-friction ──────────────────────────────────────
# Execute a promotion decision for a single friction entry.
#
# MVP scope: --target archive chains to archive-friction-entries.
# For task/decision/feedback targets, the script doesn't auto-scaffold —
# slug/title/body need conversation context, so Petra writes those files
# directly via the Write tool. The script then can be called with
# --target archive to clean up the raw entry.
#
# Flags:
#   --entry "<date>|<desc-prefix>"   required, identifies the source entry
#   --target <archive|task|decision|feedback>   required
#
# For non-archive targets, emits a hint with the suggested scaffold path
# and exits 0 without modifying anything. Petra then writes the file
# and re-invokes with --target archive.
do_promote_friction() {
  local entry=""
  local target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --entry)  entry="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      *) echo "[promote-friction] unknown arg: $1" >&2; return 2 ;;
    esac
  done
  if [ -z "$entry" ] || [ -z "$target" ]; then
    echo "[promote-friction] usage: promote-friction --entry '<date>|<prefix>' --target <archive|task|decision|feedback>" >&2
    return 2
  fi
  case "$target" in
    archive)
      do_archive_friction_entries --entry "$entry"
      ;;
    task|decision|feedback)
      local date_part="${entry%%|*}"
      local prefix_part="${entry#*|}"
      cat <<HINT >&2
[promote-friction] target=$target needs Petra to scaffold the file.

Source entry: $date_part — $prefix_part

Suggested next steps:
  1. Write the $target file with proper title/slug from conversation context:
HINT
      case "$target" in
        task)
          echo "       Path: \$VAULT_PATH/<ENV>/<project>/tasks/open/${date_part}-<slug>.md" >&2
          ;;
        decision)
          echo "       Path: \$VAULT_PATH/<ENV>/<project>/decisions/${date_part}-<slug>.md" >&2
          ;;
        feedback)
          echo "       Path: ~/.claude/projects/.../memory/feedback_<topic>.md" >&2
          ;;
      esac
      cat <<HINT2 >&2
  2. Add a back-link to the source friction entry.
  3. Re-invoke: forge-context.sh promote-friction --entry '$entry' --target archive
     (to remove the raw entry from friction-log.md)
HINT2
      return 0
      ;;
    *)
      echo "[promote-friction] unknown target: $target (expected archive|task|decision|feedback)" >&2
      return 2
      ;;
  esac
}

# ── Subcommand: bootstrap-harvest ────────────────────────────────────
# Non-interactive sweep that archives all unpinned/unarchived friction entries
# older than --older-than DAYS (default 30). No promotion prompts — old entries
# go straight to the per-week archive. Designed for one-shot reduction of the
# accumulated friction-log; subsequent maintenance happens via harvest-friction
# + promote-friction (Slice 3).
#
# Flags:
#   --older-than N    archive entries older than N days (default 30)
#   --dry-run         show what would be archived; don't write
#
# Output: human-readable summary line + (if --dry-run) JSON list to stdout.
do_bootstrap_harvest() {
  local days=30
  local dry_run=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --older-than) days="$2"; shift 2 ;;
      --dry-run)    dry_run=true; shift ;;
      *) echo "[bootstrap-harvest] unknown arg: $1" >&2; return 2 ;;
    esac
  done
  if [ ! -f "$FRICTION_CLASSIFIED" ]; then
    echo "[bootstrap-harvest] no friction-classified.json at $FRICTION_CLASSIFIED" >&2
    return 1
  fi

  # Compute list of entry_ids to archive via python (uses ISO dates)
  local entry_ids_raw
  entry_ids_raw="$(python3 - "$FRICTION_CLASSIFIED" "$days" <<'PYEOF'
import datetime, json, sys
classified_path, days_str = sys.argv[1:3]
days = int(days_str)
cutoff = datetime.date.today() - datetime.timedelta(days=days)
with open(classified_path) as f:
    data = json.load(f)
ids = []
for entry in data.get('entries', []):
    if entry.get('pinned') is True:
        continue
    if entry.get('archived_in'):
        continue
    date_str = entry.get('date', '')
    try:
        d = datetime.date.fromisoformat(date_str)
    except ValueError:
        continue
    if d >= cutoff:
        continue
    desc = entry.get('description', '')[:80]
    ids.append(f"{date_str}|{desc}")
for i in ids:
    print(i)
PYEOF
)"

  if [ -z "$entry_ids_raw" ]; then
    echo "[bootstrap-harvest] nothing to archive (no entries older than $days days)" >&2
    return 0
  fi

  local count
  count=$(printf '%s\n' "$entry_ids_raw" | wc -l | tr -d ' ')

  if [ "$dry_run" = "true" ]; then
    echo "[bootstrap-harvest] DRY-RUN: would archive $count entries older than $days days:" >&2
    printf '%s\n' "$entry_ids_raw"
    return 0
  fi

  echo "[bootstrap-harvest] archiving $count entries older than $days days..." >&2
  # Build --entry args from the id list
  local -a entry_args=()
  while IFS= read -r line; do
    [ -n "$line" ] && entry_args+=(--entry "$line")
  done <<< "$entry_ids_raw"

  # Match the description-prefix lengths used in friction-log.md headings.
  # archive-friction-entries uses startswith match, so the 80-char prefix
  # from JSON will match the heading title's first 80 chars (or full title
  # if shorter). This relies on the JSON description being a verbatim copy
  # of the markdown heading title — see do_append_friction.
  do_archive_friction_entries "${entry_args[@]}"
}

# ── Subcommand: audit-prose-rules ──────────────────────────────────────
# Scans for prose patterns that smell script-replaceable (MUST/Never/Remember/
# always/REQUIRED). Cross-references friction-log for recurrence signal.
# Fingerprint cache dedups across runs.
#
# Flags:
#   --json     output JSON instead of human report
#   --since DATE  accepted but currently unused (best-effort placeholder)
#
# Env overrides (for tests):
#   FORGE_AUDIT_SCAN_ROOT  (default: forge installed paths)
#   FORGE_AUDIT_CACHE      (default: ~/.cache/forge/audit-fingerprints.json)
do_audit_prose_rules() {
  local json_mode=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json_mode=true; shift ;;
      --since) shift 2 ;;
      *) shift ;;
    esac
  done

  local scan_root="${FORGE_AUDIT_SCAN_ROOT:-$HOME_DIR/.claude/skills/forge}"
  local cache="${FORGE_AUDIT_CACHE:-$HOME_DIR/.cache/forge/audit-fingerprints.json}"
  mkdir -p "$(dirname "$cache")"
  [ -f "$cache" ] || echo '{"fingerprints":[]}' > "$cache"

  local pattern_regex='\b(MUST|REQUIRED|Never|Always|always|never|Remember|REMEMBER)\b'

  local findings_raw
  findings_raw=$(grep -rEn "$pattern_regex" "$scan_root" \
    --include='*.md' --include='*.sh' 2>/dev/null || true)

  local new_findings=""
  local all_fps=""
  if [ -n "$findings_raw" ]; then
    while IFS= read -r line; do
      local fp
      fp=$(printf '%s' "$line" | shasum -a 1 2>/dev/null | awk '{print $1}')
      [ -z "$fp" ] && fp=$(printf '%s' "$line" | shasum | awk '{print $1}')
      all_fps="$all_fps $fp"
      if ! jq -e --arg f "$fp" '.fingerprints | index($f)' "$cache" > /dev/null 2>&1; then
        new_findings="$new_findings$line"$'\n'
      fi
    done <<< "$findings_raw"
  fi

  # Regenerate cache from the CURRENT scan, not by union with previous.
  # If a finding's prose is later edited or removed, its fingerprint drops out
  # and a re-introduction will re-fire as a new finding — intentional.
  local tmp_cache
  tmp_cache=$(mktemp)
  if [ -n "$all_fps" ]; then
    printf '%s\n' "$all_fps" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s '{fingerprints: .}' > "$tmp_cache"
  else
    echo '{"fingerprints":[]}' > "$tmp_cache"
  fi
  mv "$tmp_cache" "$cache"

  if [ "$json_mode" = "true" ]; then
    if [ -n "$new_findings" ]; then
      # NOTE: macOS `head -c -1` is unsupported (BSD head). Use sed to strip trailing newline.
      printf '%s' "$new_findings" | sed -e '$ {/^$/d;}' | jq -Rs 'split("\n") | map(select(length > 0)) | map(split(":") | {file: .[0], line: .[1], match: (.[2:] | join(":"))}) | {findings: .}'
    else
      echo '{"findings":[]}'
    fi
  else
    if [ -z "$new_findings" ]; then
      echo "[audit] no new findings (0 new since last run)"
    else
      local count
      # `grep -c .` returns 1 on zero matches AND prints "0". Combined with `|| echo 0`
      # under set -e, that produced "0\n0". Use wc -l on non-empty input directly.
      count=$(printf '%s\n' "$new_findings" | sed -e '$ {/^$/d;}' | grep -c . 2>/dev/null || true)
      [ -z "$count" ] && count=0
      echo "[audit] $count new finding(s):"
      # Reformat each grep line "file:lineno:content" to "<KEYWORD> <file>:<lineno>: <content>"
      # so callers can pattern-match on "<KEYWORD>.*<filename>" without caring about path prefixes.
      local line file_part lineno content first_match
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        file_part=$(printf '%s' "$line" | awk -F: '{print $1}')
        lineno=$(printf '%s' "$line" | awk -F: '{print $2}')
        content=$(printf '%s' "$line" | cut -d: -f3-)
        first_match=$(printf '%s' "$content" | grep -oE "$pattern_regex" | head -1)
        printf '%s %s:%s: %s\n' "${first_match:-MATCH}" "$file_part" "$lineno" "$content"
      done <<< "$new_findings"
    fi
  fi
}

# ── Subcommand: skill-budgets ──────────────────────────────────────────
# Reads $FORGE_REPO/core/skill-budgets.conf (lines of "path=N"), wc -l
# each file, classifies green (≤80% of budget) / yellow (80–100%) / red
# (>100%). Default human table; --json for machine output; --quiet to
# suppress green rows. Exit 1 if any red row, else 0.
#
# Why no install-time copy of the config: budgets are intrinsically tied
# to source-repo paths, so reading from $FORGE_REPO avoids drift.
do_skill_budgets() {
  local json_mode=false quiet_mode=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)  json_mode=true; shift ;;
      --quiet) quiet_mode=true; shift ;;
      *) shift ;;
    esac
  done

  local forge_repo
  forge_repo=$(grep '^FORGE_REPO=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)
  if [ -z "$forge_repo" ]; then
    echo "[skill-budgets] FORGE_REPO not set in $FORGE_CONF" >&2
    exit 2
  fi

  local conf="$forge_repo/core/skill-budgets.conf"
  if [ ! -f "$conf" ]; then
    echo "[skill-budgets] config not found: $conf" >&2
    exit 2
  fi

  local use_color=false
  if [ "$json_mode" = "false" ] && [ -t 1 ]; then
    use_color=true
  fi
  local c_green="" c_yellow="" c_red="" c_reset=""
  if [ "$use_color" = "true" ]; then
    c_green=$'\033[32m'
    c_yellow=$'\033[33m'
    c_red=$'\033[31m'
    c_reset=$'\033[0m'
  fi

  local rows="[]"
  local any_red=false
  local any_row=false

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in *=*) ;; *) continue ;; esac

    any_row=true
    local rel_path budget full status pct actual
    rel_path="${line%%=*}"
    budget="${line#*=}"
    rel_path="$(printf '%s' "$rel_path" | sed -e 's/[[:space:]]*$//')"
    budget="$(printf '%s' "$budget" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if ! printf '%s' "$budget" | grep -qE '^[0-9]+$'; then
      status="red"; actual="0"; pct="0"
      any_red=true
      rows=$(printf '%s' "$rows" | jq --arg p "$rel_path" --arg b "$budget" '. + [{path:$p, actual:0, budget:0, pct:0, status:"red", note:"invalid budget"}]')
      continue
    fi

    full="$forge_repo/$rel_path"
    if [ ! -f "$full" ]; then
      status="red"; actual="N/A"; pct="N/A"
      any_red=true
      rows=$(printf '%s' "$rows" | jq --arg p "$rel_path" --argjson b "$budget" '. + [{path:$p, actual:null, budget:$b, pct:null, status:"red", note:"FILE NOT FOUND"}]')
      continue
    fi

    if ! actual=$(wc -l < "$full" 2>/dev/null); then
      status="red"; actual="N/A"; pct="N/A"
      any_red=true
      rows=$(printf '%s' "$rows" | jq --arg p "$rel_path" --argjson b "$budget" '. + [{path:$p, actual:null, budget:$b, pct:null, status:"red", note:"READ ERROR"}]')
      continue
    fi
    actual=$(printf '%s' "$actual" | tr -d '[:space:]')

    if [ "$budget" -le 0 ]; then
      pct=0
    else
      pct=$(( actual * 100 / budget ))
    fi

    if [ "$pct" -le 80 ]; then
      status="green"
    elif [ "$pct" -le 100 ]; then
      status="yellow"
    else
      status="red"
      any_red=true
    fi

    rows=$(printf '%s' "$rows" | jq --arg p "$rel_path" --argjson a "$actual" --argjson b "$budget" --argjson pc "$pct" --arg s "$status" '. + [{path:$p, actual:$a, budget:$b, pct:$pc, status:$s}]')
  done < "$conf"

  if [ "$any_row" = "false" ]; then
    if [ "$json_mode" = "true" ]; then
      echo "[]"
    else
      echo "[skill-budgets] no budgets configured in $conf"
    fi
    exit 0
  fi

  if [ "$json_mode" = "true" ]; then
    printf '%s\n' "$rows" | jq .
  else
    # In quiet mode, only print header if at least one non-green row exists.
    # Without this, --quiet on an all-green run prints just the header — noise
    # for pre-commit / pipe consumers that expect empty stdout on success.
    if [ "$quiet_mode" = "false" ] || printf '%s' "$rows" | jq -e 'any(.[]; .status != "green")' >/dev/null 2>&1; then
      printf '%-7s %-70s %-12s %s\n' "STATUS" "PATH" "ACTUAL/BUDGET" "PCT"
    fi
    printf '%s\n' "$rows" | jq -r '.[] | [.status, .path, (.actual|tostring), (.budget|tostring), (.pct|tostring), (.note // "")] | @tsv' | \
    while IFS=$'\t' read -r st path actual_v budget_v pct_v note; do
      if [ "$quiet_mode" = "true" ] && [ "$st" = "green" ]; then
        continue
      fi
      local color="" label
      case "$st" in
        green)  color="$c_green";  label="GREEN " ;;
        yellow) color="$c_yellow"; label="YELLOW" ;;
        red)    color="$c_red";    label="RED   " ;;
      esac
      local pct_str="${pct_v}%"
      [ "$pct_v" = "null" ] && pct_str="N/A"
      local count_str="${actual_v}/${budget_v}"
      [ "$actual_v" = "null" ] && count_str="N/A/${budget_v}"
      if [ -n "$note" ]; then
        printf '%s%s%s %-70s %-12s %-6s %s\n' "$color" "$label" "$c_reset" "$path" "$count_str" "$pct_str" "($note)"
      else
        printf '%s%s%s %-70s %-12s %s\n' "$color" "$label" "$c_reset" "$path" "$count_str" "$pct_str"
      fi
    done
  fi

  if [ "$any_red" = "true" ]; then
    exit 1
  fi
}

# ── Subcommand: framework-budget ───────────────────────────────────────
# Reads $FORGE_REPO/core/framework-budget.conf (lines of "<category>|<label>|
# <source-type>|<source-spec>"), measures bytes for each component (file = wc
# -c on path; script-out = run command and wc -c the stdout), groups by
# category, computes totals, identifies top 3 hot spots. Default human table
# with subtotals; --json for machine output; --quiet for one-line summary.
#
# Token estimation heuristic: bytes / 4 (~0.25 tokens per byte). Not BPE-
# precise; close enough for sorting and hot-spot identification.
#
# Missing-source handling: components whose source path doesn't exist or
# whose script invocation fails report 0 bytes and continue (no crash).
#
# Why config-driven: the component list evolves as Forge changes; editing
# the config is lighter than patching the script. Follows skill-budgets
# precedent.
do_framework_budget() {
  local json_mode=false quiet_mode=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)  json_mode=true; shift ;;
      --quiet) quiet_mode=true; shift ;;
      --help|-h)
        cat <<'EOF'
forge-context.sh framework-budget — measure framework entry tax

Reports per-component byte/token cost of what every Forge session pays
before any project work begins. Components are defined in
$FORGE_REPO/core/framework-budget.conf.

Usage:
  forge-context.sh framework-budget          Human-readable table (default)
  forge-context.sh framework-budget --json   Machine-readable JSON
  forge-context.sh framework-budget --quiet  One-line summary
  forge-context.sh framework-budget --help   This help
EOF
        return 0 ;;
      *) shift ;;
    esac
  done

  local forge_repo
  forge_repo=$(grep '^FORGE_REPO=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)
  if [ -z "$forge_repo" ]; then
    echo "[framework-budget] FORGE_REPO not set in $FORGE_CONF" >&2
    exit 2
  fi

  local conf="$forge_repo/core/framework-budget.conf"
  if [ ! -f "$conf" ]; then
    echo "[framework-budget] config not found: $conf" >&2
    exit 2
  fi

  # Expand $HOME / $VAULT_PATH / $FORGE_REPO / $HOME_DIR in source specs.
  # These are the only allowed expansion vars; everything else is literal.
  local home_dir="${HOME_DIR:-$HOME}"
  local vault_path
  vault_path=$(grep '^VAULT_PATH=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)

  local rows="[]"

  while IFS= read -r line || [ -n "$line" ]; do
    # Strip comments and trim whitespace.
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in *\|*\|*\|*) ;; *) continue ;; esac

    local category label source_type source_spec
    category="${line%%|*}"; line="${line#*|}"
    label="${line%%|*}"; line="${line#*|}"
    source_type="${line%%|*}"; source_spec="${line#*|}"

    # Expand allowed vars. Use plain sed substitution rather than eval to
    # avoid arbitrary-code-execution risk from config contents.
    local expanded="$source_spec"
    expanded="${expanded//\$HOME/$HOME}"
    expanded="${expanded//\$HOME_DIR/$home_dir}"
    expanded="${expanded//\$VAULT_PATH/$vault_path}"
    expanded="${expanded//\$FORGE_REPO/$forge_repo}"

    local bytes=0
    case "$source_type" in
      file)
        if [ -f "$expanded" ]; then
          bytes=$(wc -c < "$expanded" 2>/dev/null | tr -d '[:space:]' || echo 0)
        fi
        ;;
      script-out)
        # source_spec is "<command> <args...>". Run via bash -c, capture stdout
        # bytes only (discard stderr to keep noise out of the count).
        if command -v bash >/dev/null 2>&1; then
          # shellcheck disable=SC2086
          bytes=$(bash -c "$expanded" 2>/dev/null | wc -c | tr -d '[:space:]' || echo 0)
        fi
        ;;
      *)
        bytes=0
        ;;
    esac

    [ -z "$bytes" ] && bytes=0

    rows=$(printf '%s' "$rows" | jq \
      --arg cat "$category" \
      --arg lab "$label" \
      --arg src "$source_type" \
      --argjson b "$bytes" \
      '. + [{category:$cat, label:$lab, source_type:$src, bytes:$b, kb:($b/1024|floor), est_tokens:($b/4|floor)}]')
  done < "$conf"

  # Aggregate by category.
  local cats
  cats=$(printf '%s' "$rows" | jq '[group_by(.category)[] | {category:.[0].category, bytes:(map(.bytes)|add), kb:((map(.bytes)|add)/1024|floor), est_tokens:((map(.bytes)|add)/4|floor), count:length}]')

  # Total.
  local total
  total=$(printf '%s' "$rows" | jq '{bytes:(map(.bytes)|add), kb:((map(.bytes)|add)/1024|floor), est_tokens:((map(.bytes)|add)/4|floor)}')

  # Top 3 hot spots (by bytes, descending).
  local top
  top=$(printf '%s' "$rows" | jq '[sort_by(-.bytes) | .[0:3] | .[] | {label, kb, bytes}]')

  if [ "$json_mode" = "true" ]; then
    jq -n --argjson c "$rows" --argjson ag "$cats" --argjson t "$total" --argjson hs "$top" \
      '{components: $c, categories: $ag, total: $t, top_hot_spots: $hs}'
    return 0
  fi

  if [ "$quiet_mode" = "true" ]; then
    local total_kb total_tok total_count
    total_kb=$(printf '%s' "$total" | jq -r '.kb')
    total_tok=$(printf '%s' "$total" | jq -r '.est_tokens')
    total_count=$(printf '%s' "$rows" | jq 'length')
    local cat_count
    cat_count=$(printf '%s' "$cats" | jq 'length')
    echo "Framework entry tax: ${total_kb} KB, ~${total_tok} tokens (${total_count} components across ${cat_count} categories)"
    return 0
  fi

  # Human mode: grouped table.
  echo "Framework entry tax — token-footprint audit"
  echo "============================================"
  echo ""

  local cat_list
  cat_list=$(printf '%s' "$cats" | jq -r '.[].category')
  for c in $cat_list; do
    local cat_count cat_kb cat_tok
    cat_count=$(printf '%s' "$cats" | jq -r --arg c "$c" '.[] | select(.category == $c) | .count')
    cat_kb=$(printf '%s' "$cats" | jq -r --arg c "$c" '.[] | select(.category == $c) | .kb')
    cat_tok=$(printf '%s' "$cats" | jq -r --arg c "$c" '.[] | select(.category == $c) | .est_tokens')
    printf '%s (%s component%s):\n' "$c" "$cat_count" "$([ "$cat_count" -eq 1 ] && echo "" || echo "s")"
    printf '%s' "$rows" | jq -r --arg c "$c" '.[] | select(.category == $c) | "  \(.label)|\(.kb)|\(.est_tokens)"' | \
      while IFS='|' read -r lab kb tok; do
        printf '  %-44s %6s KB  ~%6s tok\n' "$lab" "$kb" "$tok"
      done
    printf '  %-44s %6s KB  ~%6s tok\n' " " "──────" "─────────"
    printf '  %-44s %6s KB  ~%6s tok\n' " " "$cat_kb" "$cat_tok"
    echo ""
  done

  echo "═══════════════════════════════════════════════════════════════════════════"
  local t_kb t_tok
  t_kb=$(printf '%s' "$total" | jq -r '.kb')
  t_tok=$(printf '%s' "$total" | jq -r '.est_tokens')
  printf 'TOTAL: %s KB  ~%s tokens framework entry tax\n' "$t_kb" "$t_tok"
  echo "═══════════════════════════════════════════════════════════════════════════"
  echo ""
  echo "Top 3 hot spots:"
  printf '%s' "$top" | jq -r '.[] | "\(.label)|\(.kb)"' | nl -w2 -s'. ' | \
    while IFS='|' read -r prefix_label kb; do
      printf '  %s %6s KB\n' "$prefix_label" "$kb"
    done
}

# ── Subcommand: bootstrap-classify ──────────────────────────────────────
# One-shot. Reads existing friction-log.md, runs keyword-heuristic
# classification, writes friction-classified.json. Used to retro-fit the
# friction-meta-framework onto historical entries that pre-date append-friction.
do_bootstrap_classify() {
  if [ ! -f "$FRICTION_LOG" ]; then
    echo "[bootstrap-classify] no friction-log at $FRICTION_LOG; nothing to do"
    echo '{"entries":[]}' > "$FRICTION_CLASSIFIED"
    return 0
  fi

  # Parse: each entry starts with ## or ### YYYY-MM-DD — description.
  # Historical hand-written entries use ##; future append-friction entries use ###. Accept both.
  local entries_json="[]"
  local current_date="" current_desc="" current_body=""

  process_entry() {
    [ -z "$current_date" ] && return
    [ -z "$current_desc" ] && return
    local combined="$current_desc $current_body"
    local pattern="needs_new_pattern"
    # Heuristics (case-insensitive)
    if echo "$combined" | grep -qiE 'permission prompt|allowlist|approval prompt'; then
      pattern="allowlist-patch"
    elif echo "$combined" | grep -qiE 'hook (fired|misfire|wrongly)|nag (fired|during entry)'; then
      pattern="marker-state-guard"
    elif echo "$combined" | grep -qiE 'header|format drift|verbatim|reproduce'; then
      pattern="hook-injection"
    elif echo "$combined" | grep -qiE 'compound command|heredoc|wrapper|subcommand'; then
      pattern="wrapper-subcommand"
    elif echo "$combined" | grep -qiE 'template|frontmatter|structured (text|format)'; then
      pattern="template-slot"
    fi
    entries_json=$(echo "$entries_json" | jq \
      --arg d "$current_date" \
      --arg desc "$current_desc" \
      --arg p "$pattern" \
      '. += [{date: $d, description: $desc, pattern: $p, recurrence: 1, action_ref: "needs_new_pattern", validation_failed: false, original_pattern: $p}]')
  }

  local line
  while IFS= read -r line; do
    # Accept em-dash (—) OR ASCII hyphen (-) as separator: append-friction emits em-dash,
    # but historical hand-written entries often use a plain hyphen.
    if [[ "$line" =~ ^###?[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+[—-][[:space:]]+(.+)$ ]]; then
      process_entry
      current_date="${BASH_REMATCH[1]}"
      current_desc="${BASH_REMATCH[2]}"
      current_body=""
    else
      current_body="$current_body $line"
    fi
  done < "$FRICTION_LOG"
  process_entry

  echo "$entries_json" | jq '{entries: .}' > "$FRICTION_CLASSIFIED"
  local count
  count=$(echo "$entries_json" | jq 'length')
  echo "[bootstrap-classify] classified $count entries → $FRICTION_CLASSIFIED"
}

# ── Subcommand: learn-wind-down (slice 3 — personal phrase learning) ──
# Append a user-confirmed wind-down phrase to the personal vault list at
# ${VAULT_PATH}/_shared/wind-down-phrases.json. Normalizes the phrase
# (lowercase, trim, collapse internal whitespace) before dedup so different
# castings of the same phrase don't get stored as separate entries.
#
# File format: {"phrases": ["phrase1", "phrase2", ...]}
#
# Behavior:
#   - File missing → initialize with empty array, then append
#   - Phrase already present (after normalization) → no-op, exit 0
#   - jq not available → fall back to plain-text append in a sibling
#     `.txt` file so we don't silently drop the learning signal
#
# Usage: forge-context.sh learn-wind-down "<phrase>"
do_learn_wind_down() {
  local phrase="${1:-}"
  if [ -z "$phrase" ]; then
    echo "[forge-context] learn-wind-down requires <phrase> arg" >&2
    exit 1
  fi

  local file="$VAULT_PATH/_shared/wind-down-phrases.json"
  mkdir -p "$(dirname "$file")"

  # Normalize: lowercase, trim, collapse internal whitespace
  local normalized
  normalized=$(printf '%s' "$phrase" | tr '[:upper:]' '[:lower:]' | awk '{$1=$1; print}')
  if [ -z "$normalized" ]; then
    echo "[forge-context] learn-wind-down: phrase empty after normalization" >&2
    exit 1
  fi

  # jq fallback — plain-text append, marked for later migration
  if ! command -v jq >/dev/null 2>&1; then
    local txt_fallback="$VAULT_PATH/_shared/wind-down-phrases.txt"
    if ! grep -Fxq "$normalized" "$txt_fallback" 2>/dev/null; then
      printf '%s\n' "$normalized" >> "$txt_fallback"
      echo "Logged '$normalized' to $txt_fallback (jq missing — JSON store skipped)"
    else
      echo "Already in list: '$normalized'"
    fi
    return 0
  fi

  if [ ! -f "$file" ]; then
    printf '{"phrases": []}\n' > "$file"
  fi

  if jq -e --arg p "$normalized" '.phrases | index($p) != null' "$file" >/dev/null 2>&1; then
    echo "Already in list: '$normalized'"
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  if jq --arg p "$normalized" '.phrases += [$p]' "$file" > "$tmp"; then
    mv "$tmp" "$file"
    echo "Logged '$normalized' to $file"
  else
    rm -f "$tmp"
    echo "[forge-context] learn-wind-down: jq update failed" >&2
    exit 1
  fi
}

# ── Subcommand: wind-down-list (slice 3 — discoverability) ────────────
# Print the user's personal wind-down phrases, one per line. Silent-ok when
# the file doesn't exist yet (returns 0, no output) so callers can pipe it
# without conditionals.
do_wind_down_list() {
  local file="$VAULT_PATH/_shared/wind-down-phrases.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    cat "$file"
    return 0
  fi
  jq -r '.phrases[]?' "$file"
}

# ── Subcommand: next-meeting ──────────────────────────────────────────
# Print the next non-declined calendar meeting starting within $MEETING_WINDOW_MIN
# minutes (loaded from forge.conf at startup, default 30).
#
# Output: a single line `HH:MM|title|minutes_until`, or no output when nothing
# is imminent / calendar disabled / fetch failed. Petra chains this with
# `wrap-up-state` at wrap-up moments so she paces against both EOD and any
# imminent meeting interruption.
#
# Delegates to forge-calendar.sh next-meeting which owns the gws call.
do_next_meeting() {
  local calendar_sh="$HOME_DIR/.claude/scripts/forge-calendar.sh"
  [ -x "$calendar_sh" ] || return 0
  "$calendar_sh" next-meeting "$MEETING_WINDOW_MIN" 2>/dev/null || true
}

# ── Subcommand: substrate-check ───────────────────────────────────────
# Detect whether agent-team substrate (tmux + $TMUX env) is available for
# Pattern A dispatch. Emits a single ready-to-surface line.
#
# Output: one of
#   "Team substrate: ready"
#   "Team substrate: missing — relaunch in tmux for Pattern A, or accept inline subagent fallback"
#   "Team substrate: missing — install tmux (\`brew install tmux\`) and relaunch for Pattern A; inline subagent fallback works either way"
#
# Why a subcommand instead of inline Bash at entry: the inline compound
# (echo + command -v + && / || chain) is not matched by any flat allowlist
# entry, so it prompts the user on every session start. Routing through
# forge-context.sh inherits the existing script-level allowlist and stays
# silent. Petra surfaces the output verbatim in the entry-summary block.
do_substrate_check() {
  if [ -n "${TMUX:-}" ]; then
    echo "Team substrate: ready"
    return 0
  fi
  if command -v tmux >/dev/null 2>&1; then
    echo "Team substrate: missing — relaunch in tmux for Pattern A, or accept inline subagent fallback"
  else
    echo "Team substrate: missing — install tmux (\`brew install tmux\`) and relaunch for Pattern A; inline subagent fallback works either way"
  fi
}

# ── Subcommand: review-sync ────────────────────────────────────────────
# Scan tasks/reviews/ for PR-numbered review docs, query gh for each PR's
# state, and emit one line per doc whose PR is merged or closed-unmerged
# (i.e. ripe for the /promote-from-review cleanup flow).
#
# Output format (one line per merged/closed review doc):
#   ~ #<num> <title-prefix>: <state> — review doc cleanup queued
# where the leading `~` distinguishes reviewed-PR rows from own-PR rows
# in the entry-summary PR Sync block. Silent on open PRs (still active —
# review doc legitimately in place). Silent when no review docs exist.
#
# Args:
#   (default)   — scan the ACTIVE project only (resolved from forge-active marker)
#   --backfill  — scan every {ENV}/{PROJECT}/tasks/reviews/ under VAULT_PATH
#
# PR-number extraction: regex over filename + first 20 lines of each doc,
# dedup. Pattern: `pr-(\d+)` OR `#(\d+)` (capped at 4-6 digits to avoid
# matching anchors).
#
# Cross-host: per-project. Each project's git remote determines (host,
# owner/repo) for the gh call. Matches the existing PR sync pattern.
#
# Cost: one `gh pr view` per (doc, PR), typically ≤5 docs per project.
# Each call ~200ms. Acceptable for entry-time invocation.
do_review_sync() {
  local mode="${1:-active}"
  local scan_dirs=()

  case "$mode" in
    --backfill|backfill)
      # All projects: walk every {ENV}/{PROJECT}/tasks/reviews
      local env_dir env_name proj_dir
      for env_dir in "$VAULT_PATH"/*/; do
        [ -d "$env_dir" ] || continue
        env_name="$(basename "$env_dir")"
        case "$env_name" in _*) continue ;; esac
        for proj_dir in "$env_dir"*/; do
          [ -d "$proj_dir" ] || continue
          [ -d "${proj_dir%/}/tasks/reviews" ] || continue
          scan_dirs+=("${proj_dir%/}")
        done
      done
      ;;
    active|"")
      # Active project only — resolve via marker
      [ -f "$MARKER" ] || return 0
      local project; project="$(extract_marker_project)" || return 0
      [ -n "$project" ] || return 0
      local proj_dir; proj_dir="$(get_vault_dir "$project")"
      [ -d "$proj_dir/tasks/reviews" ] || return 0
      scan_dirs+=("$proj_dir")
      ;;
    *)
      echo "[review-sync] unknown mode: $mode (try: active | --backfill)" >&2
      return 2
      ;;
  esac

  command -v gh >/dev/null 2>&1 || return 0

  local scan_dir reviews_dir
  for scan_dir in "${scan_dirs[@]}"; do
    reviews_dir="$scan_dir/tasks/reviews"

    # Resolve project's git remote → (host, repo) for gh calls
    local project_dir_for_git project_name
    project_name="$(basename "$scan_dir")"
    project_dir_for_git="$(get_project_dir "$project_name" 2>/dev/null || true)"
    [ -d "$project_dir_for_git/.git" ] || continue

    local remote host repo
    remote="$(git -C "$project_dir_for_git" remote get-url origin 2>/dev/null || true)"
    [ -n "$remote" ] || continue
    host="$(echo "$remote" | sed -nE 's#^(https?://|git@)([^/:]+)[/:].*#\2#p')"
    [ -z "$host" ] && host="github.com"
    repo="$(echo "$remote" | sed "s|.*${host}[:/]||;s|\.git$||")"

    # Walk review docs, extract PR numbers, dedup
    local f
    for f in "$reviews_dir"/*.md; do
      [ -f "$f" ] || continue
      # Filename + first 20 lines content
      local extracted
      extracted=$(
        {
          basename "$f"
          head -n 20 "$f" 2>/dev/null
        } |
          grep -oE 'pr-[0-9]{3,6}|#[0-9]{3,6}' |
          sed -E 's/^(pr-|#)//' |
          sort -un
      )
      [ -n "$extracted" ] || continue

      local pr_num
      while IFS= read -r pr_num; do
        [ -n "$pr_num" ] || continue
        # Query gh — state + title; silent on failure
        local pr_json state title
        pr_json="$(GH_HOST="$host" gh pr view "$pr_num" --repo "$repo" \
                    --json state,title 2>/dev/null || true)"
        [ -n "$pr_json" ] || continue
        state="$(echo "$pr_json" | jq -r '.state // empty' 2>/dev/null)"
        title="$(echo "$pr_json" | jq -r '.title // empty' 2>/dev/null)"
        case "$state" in
          MERGED|CLOSED)
            # Truncate title to 50 chars for the row
            local short_title="${title:0:50}"
            printf '~ #%s %s: %s — review doc cleanup queued\n' \
              "$pr_num" "$short_title" "$state"
            ;;
          OPEN|*)
            # Silent — review doc legitimately still active
            ;;
        esac
      done <<< "$extracted"
    done
  done
}

# ── Subcommand: draft-list ────────────────────────────────────────────
# Enumerate captured draft tasks across all draft folders for the weekly-wrap
# triage step. Output is TSV with columns: path \t project \t title.
#
# - path:    full path to the draft .md file
# - project: from frontmatter `project:` if set; else inferred from the path
#            (e.g. /vault/PERSO/forge/tasks/draft/ → "PERSO/forge"); else "—"
# - title:   first `# ` heading or the filename (no .md) if heading absent
#
# Skips files under `_discarded/` subdirs (those are awaiting auto-purge).
# Silent when no drafts exist anywhere — `forge-weekly` Step 2 short-circuits.
#
# Slice B of [[2026-05-05-user-draft-task-capture]]. Slice A shipped the
# capture template + docs; this subcommand powers the triage step Petra
# walks the user through during the weekly ceremony.
do_draft_list() {
  [ -z "${VAULT_PATH:-}" ] && return 0
  [ -d "$VAULT_PATH" ] || return 0
  # find every `tasks/draft` dir under VAULT_PATH; iterate the .md files in
  # each, skipping the `_discarded/` grace-period subdir.
  find "$VAULT_PATH" -type d -name draft -path "*/tasks/draft" -print0 2>/dev/null |
  while IFS= read -r -d '' draft_dir; do
    for f in "$draft_dir"/*.md; do
      [ -f "$f" ] || continue
      case "$f" in *"/_discarded/"*) continue ;; esac

      # Extract `project:` from frontmatter (between the first two `---` lines)
      local project title rel
      project=$(awk '
        /^---[[:space:]]*$/ { c++; if (c==2) exit; next }
        c==1 && /^project:/ {
          sub(/^project:[[:space:]]*/, "")
          sub(/[[:space:]]+$/, "")
          print; exit
        }
      ' "$f")

      # First H1 heading; fall back to filename (no .md)
      title=$(grep -m1 '^# ' "$f" 2>/dev/null | sed 's/^# //')
      [ -z "$title" ] && title=$(basename "$f" .md)

      # Infer project from path when frontmatter is blank
      if [ -z "$project" ]; then
        rel="${f#$VAULT_PATH/}"
        # Match {ENV}/{PROJECT}/tasks/draft/...  (NOT _shared/tasks/draft/...)
        if [[ "$rel" =~ ^([^/_][^/]*)/([^/]+)/tasks/draft/ ]]; then
          project="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        fi
      fi

      printf "%s\t%s\t%s\n" "$f" "${project:-—}" "$title"
    done
  done
}

# ── Dispatch ────────────────────────────────────────────────────────────
SUBCMD="${1:-}"

case "$SUBCMD" in
  post-tool)           do_post_tool ;;
  gate)                do_gate ;;
  stop)                do_stop ;;
  recover)             do_recover ;;
  reconcile-marker)    reconcile_marker ;;
  status)              do_status ;;
  vault-sync)          do_vault_sync "${@:2}" ;;
  wrap-up-state)       do_wrap_up_state ;;
  weekly-wrap-due)     do_weekly_wrap_due ;;
  mark-weekly-wrap-done) do_mark_weekly_wrap_done ;;
  check-install)       do_check_install ;;
  rollback-install)    do_rollback_install "${@:2}" ;;
  open-task-audit)     do_open_task_audit ;;
  backlog-audit)       do_backlog_audit ;;
  set-marker)          do_set_marker "${@:2}" ;;
  append-braindump)    do_append_braindump "${@:2}" ;;
  append-friction)     do_append_friction "${@:2}" ;;
  friction-tail)       do_friction_tail "${@:2}" ;;
  pin-friction)        do_pin_friction "${@:2}" ;;
  archive-friction-entries) do_archive_friction_entries "${@:2}" ;;
  harvest-friction)    do_harvest_friction "${@:2}" ;;
  promote-friction)    do_promote_friction "${@:2}" ;;
  bootstrap-harvest)   do_bootstrap_harvest "${@:2}" ;;
  audit-prose-rules)   do_audit_prose_rules "${@:2}" ;;
  skill-budgets)       do_skill_budgets "${@:2}" ;;
  framework-budget)    do_framework_budget "${@:2}" ;;
  bootstrap-classify)  do_bootstrap_classify "${@:2}" ;;
  resolve-task)        do_resolve_task "${@:2}" ;;
  learn-wind-down)     do_learn_wind_down "${@:2}" ;;
  wind-down-list)      do_wind_down_list ;;
  next-meeting)        do_next_meeting ;;
  substrate-check)     do_substrate_check ;;
  review-sync)         do_review_sync "${@:2}" ;;
  draft-list)          do_draft_list ;;
  *)
    echo "Usage: forge-context.sh {post-tool|gate|stop|recover|reconcile-marker|status|vault-sync|wrap-up-state|weekly-wrap-due|mark-weekly-wrap-done|check-install|rollback-install|open-task-audit|backlog-audit|set-marker|append-braindump|append-friction|friction-tail|pin-friction|archive-friction-entries|harvest-friction|promote-friction|bootstrap-harvest|audit-prose-rules|skill-budgets|framework-budget|bootstrap-classify|resolve-task|learn-wind-down|wind-down-list|next-meeting|substrate-check|review-sync|draft-list}" >&2
    exit 1
    ;;
esac
