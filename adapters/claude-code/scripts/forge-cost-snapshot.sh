#!/usr/bin/env bash
# forge-cost-snapshot.sh — context-economy snapshot for the current Claude Code session
#
# Reads the session JSONL (~/.claude/projects/<machine-slug>/<session_id>.jsonl)
# and reports content-byte breakdown, cache_read trajectory, top tool_results,
# and whether Petra should suggest /compact based on:
#   cache_read > 500K AND no ≥10% turn-to-turn drop in last 20 turns.
#
# Usage:
#   forge-cost-snapshot.sh             Human-readable summary (default)
#   forge-cost-snapshot.sh --json      Machine-readable JSON (for Petra/Keeper)
#   forge-cost-snapshot.sh --session ID  Override session (default: $CLAUDE_CODE_SESSION_ID)
#   forge-cost-snapshot.sh --help      Usage

set -uo pipefail  # NOT -e: handle errors gracefully via emit_error

JSON_MODE=false
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_MODE=true; shift ;;
    --session) SESSION_ID="${2:-}"; shift 2 ;;
    --help|-h)
      sed -n 's/^# \{0,1\}//p' "$0" | head -20
      exit 0
      ;;
    *) echo "unknown arg: $1 (try --help)" >&2; exit 1 ;;
  esac
done

# Resolve JSONL path: ~/.claude/projects/<machine-slug>/<session_id>.jsonl
# Machine slug = $HOME with every non-alphanumeric char (/, ., @, _, etc.)
# replaced by `-`. Verified empirically against the directory CC creates.
# Example: /Users/shiva.bernhard@m10s.io → -Users-shiva-bernhard-m10s-io
PROJECT_SLUG="$(echo "$HOME" | sed 's|[^[:alnum:]]|-|g')"
JSONL_PATH="$HOME/.claude/projects/${PROJECT_SLUG}/${SESSION_ID}.jsonl"

emit_error() {
  local err="$1"
  if [ "$JSON_MODE" = true ]; then
    printf '{"error": "%s", "suggest_compact": false}\n' "$err"
  else
    echo "cost-snapshot: $err" >&2
  fi
  exit 0
}

[ -z "$SESSION_ID" ] && emit_error "no-session-id (CLAUDE_CODE_SESSION_ID unset)"
[ ! -f "$JSONL_PATH" ] && emit_error "jsonl-not-found at $JSONL_PATH"

# Total bytes — cheap, no jq.
TOTAL_BYTES=$(wc -c < "$JSONL_PATH" 2>/dev/null || echo 0)
TOTAL_KB=$(( TOTAL_BYTES / 1024 ))

# Per-type byte breakdown — single jq pass. Defensive on missing fields.
# Slurp the JSONL into an array, filter to user/assistant records, sum content
# bytes per type. Thinking-block byte cost is the signature blob (the "thinking"
# text field is empty on disk in current CC; signature is what persists and
# re-costs in cache_read).
JQ_OUT=$(jq -r --slurp '
  [.[] | select(. != null and (.type? == "assistant" or .type? == "user"))] as $turns
  | [$turns[] | (.message.content // []) | .[]?] as $blocks
  | [
      ([$blocks[] | select(.type == "text") | (.text // "" | tostring | length)] | add // 0),
      ([$blocks[] | select(.type == "thinking") | ((.signature // "" | tostring | length) + (.text // "" | tostring | length))] | add // 0),
      ([$blocks[] | select(.type == "tool_use") | (.input | tostring | length)] | add // 0),
      ([$blocks[] | select(.type == "tool_result") | (.content | tostring | length)] | add // 0),
      ($turns | length)
    ]
  | "\(.[0]) \(.[1]) \(.[2]) \(.[3]) \(.[4])"
' "$JSONL_PATH" 2>/dev/null || echo "0 0 0 0 0")

read -r TEXT_BYTES THINKING_BYTES TOOL_USE_BYTES TOOL_RESULT_BYTES TURN_COUNT <<< "$JQ_OUT"
TEXT_KB=$(( ${TEXT_BYTES:-0} / 1024 ))
THINKING_KB=$(( ${THINKING_BYTES:-0} / 1024 ))
TOOL_USE_KB=$(( ${TOOL_USE_BYTES:-0} / 1024 ))
TOOL_RESULT_KB=$(( ${TOOL_RESULT_BYTES:-0} / 1024 ))
TURN_COUNT=${TURN_COUNT:-0}

# Cache_read trajectory — last 20 assistant turns with usage records.
# CSV output for awk processing; empty if Vertex API (no cache_read field) or
# insufficient turns.
TRAJECTORY=$(jq -r --slurp '
  [.[] | select(. != null and .type? == "assistant" and (.message.usage.cache_read_input_tokens? // null) != null)]
  | .[-20:]
  | [.[] | .message.usage.cache_read_input_tokens]
  | @csv
' "$JSONL_PATH" 2>/dev/null || echo "")

if [ -z "$TRAJECTORY" ] || [ "$TRAJECTORY" = "null" ]; then
  CACHE_READ_CURRENT="null"
  TRAJECTORY_ARRAY="[]"
  TRAJECTORY_COUNT=0
  COMPACTION_SIGNAL="unknown"
  SUGGEST_COMPACT=false
  SUGGEST_REASON="cache_read unavailable (Vertex API or no assistant turns with usage records yet)"
else
  TRAJECTORY_ARRAY="[$TRAJECTORY]"
  CACHE_READ_CURRENT=$(echo "$TRAJECTORY" | awk -F',' '{print $NF}')
  TRAJECTORY_COUNT=$(echo "$TRAJECTORY" | awk -F',' '{print NF}')

  # Check for any 10%+ turn-to-turn drop in trajectory.
  HAS_DROP=$(echo "$TRAJECTORY" | awk -F',' '
    {
      for (i = 2; i <= NF; i++) {
        if ($i + 0 < $(i-1) * 0.9) { print "yes"; exit }
      }
      print "no"
    }
  ')

  if [ "$HAS_DROP" = "yes" ]; then
    COMPACTION_SIGNAL="recent_drop"
    SUGGEST_COMPACT=false
    SUGGEST_REASON="recent ≥10% drop in cache_read — compaction fired in the last 20 turns"
  elif [ "$TRAJECTORY_COUNT" -lt 20 ]; then
    COMPACTION_SIGNAL="unknown"
    SUGGEST_COMPACT=false
    SUGGEST_REASON="insufficient data: $TRAJECTORY_COUNT assistant turns with usage records (need 20)"
  elif [ "$CACHE_READ_CURRENT" -gt 500000 ]; then
    COMPACTION_SIGNAL="climbing"
    SUGGEST_COMPACT=true
    CR_DISPLAY=$(( CACHE_READ_CURRENT / 1000 ))
    SUGGEST_REASON="cache_read ${CR_DISPLAY}K > 500K threshold, no ≥10% drop across last 20 turns"
  else
    COMPACTION_SIGNAL="stable"
    SUGGEST_COMPACT=false
    CR_DISPLAY=$(( CACHE_READ_CURRENT / 1000 ))
    SUGGEST_REASON="cache_read ${CR_DISPLAY}K below 500K threshold"
  fi
fi

# Top tool_results — diagnostic, top 3 by KB.
TOP_TOOL_RESULTS=$(jq -r --slurp '
  [.[] | select(. != null) | .message?.content?[]? | select(.type == "tool_result")]
  | to_entries
  | map({index: .key, kb: ((.value.content | tostring | length) / 1024 | floor), tool: (.value.tool_use_id // "unknown")})
  | sort_by(.kb) | reverse | .[:3]
  | tojson
' "$JSONL_PATH" 2>/dev/null || echo "[]")

if [ "$JSON_MODE" = true ]; then
  # Escape SUGGEST_REASON for JSON safety (rare quote/backslash).
  REASON_ESCAPED=$(printf '%s' "$SUGGEST_REASON" | jq -Rs '.')
  cat <<EOF
{
  "session_id": "$SESSION_ID",
  "turns": $TURN_COUNT,
  "content_kb_total": $TOTAL_KB,
  "content_kb_by_type": {
    "text": $TEXT_KB,
    "thinking_sig": $THINKING_KB,
    "tool_use": $TOOL_USE_KB,
    "tool_result": $TOOL_RESULT_KB
  },
  "cache_read_current": $CACHE_READ_CURRENT,
  "cache_read_trajectory_last_20": $TRAJECTORY_ARRAY,
  "compaction_signal": "$COMPACTION_SIGNAL",
  "top_tool_results_kb": $TOP_TOOL_RESULTS,
  "suggest_compact": $SUGGEST_COMPACT,
  "suggest_reason": $REASON_ESCAPED
}
EOF
else
  echo "Session ${SESSION_ID:0:8} — turn $TURN_COUNT"
  echo "Content: ${TOTAL_KB} KB total (text $TEXT_KB / sig $THINKING_KB / tool_use $TOOL_USE_KB / tool_result $TOOL_RESULT_KB)"
  if [ "$CACHE_READ_CURRENT" != "null" ]; then
    echo "cache_read: $CACHE_READ_CURRENT tokens, $COMPACTION_SIGNAL"
    if [ "$SUGGEST_COMPACT" = "true" ]; then
      echo "→ consider /compact ($SUGGEST_REASON)"
    fi
  else
    echo "cache_read: unavailable ($SUGGEST_REASON)"
  fi
fi
