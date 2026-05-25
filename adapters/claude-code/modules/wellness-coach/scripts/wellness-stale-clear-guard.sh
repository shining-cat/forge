#!/usr/bin/env bash
# wellness-stale-clear-guard.sh — Layer 3 safety net from PR #26.
#
# If strike_cleared_at is recent (<1h) but last_break_timestamp is significantly
# older (>5min gap), the runtime state is inconsistent — the strike was cleared
# but the break clock wasn't reset. Self-correct by setting both break stamps
# to strike_cleared_at. One stderr line on fix; silent no-op otherwise; exit 0
# always (never blocks).
#
# Catches: manual JSON edits, future clear-path regressions, pre-PR-#26 runtime
# files that have stale state from before the cold-start ordering fix.

set -euo pipefail

VAULT_PATH=$(grep '^VAULT_PATH=' "$HOME/.claude/forge.conf" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)
SHARED_DIR="${VAULT_PATH:+$VAULT_PATH/_shared}"
[ -z "$SHARED_DIR" ] && SHARED_DIR="$HOME/.claude"
RUNTIME="$SHARED_DIR/wellness-runtime.json"

[ -f "$RUNTIME" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Use the same local-time format wellness writes, so jq's strptime+mktime
# applies the same (UTC-interpreted) offset to all three timestamps and the
# tz delta cancels in the subtraction.
now_string=$(date +"%Y-%m-%dT%H:%M:%S")

# Returns "yes" if state is inconsistent and needs correction.
needs_fix=$(jq -r --arg now "$now_string" '
  (.strike_cleared_at // null) as $sc
  | (.last_break_timestamp // null) as $lb
  | if ($sc == null or $lb == null) then "no"
    else
      ($now | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $now_ep
      | ($sc  | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $sc_ep
      | ($lb  | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $lb_ep
      | if ($now_ep - $sc_ep) < 3600 and ($sc_ep - $lb_ep) > 300
        then "yes" else "no" end
    end
' "$RUNTIME" 2>/dev/null || echo "no")

[ "$needs_fix" = "yes" ] || exit 0

tmp=$(mktemp)
jq '.last_break_timestamp = .strike_cleared_at
    | .last_micro_break_timestamp = .strike_cleared_at' \
   "$RUNTIME" > "$tmp" && mv "$tmp" "$RUNTIME"

cleared=$(jq -r '.strike_cleared_at' "$RUNTIME")
echo "[wellness] Layer-3 stale-clear self-corrected: last_break_timestamp aligned to strike_cleared_at ($cleared)" >&2
