#!/bin/bash
# forge-calendar.sh — Forge calendar layer (today's agenda + updatedMin delta)
#
# Replaces invoking the google-workspace:gws-calendar SKILL at session entry,
# which loaded the skill body into context every time. This script does the
# same agenda fetch but as a direct Bash invocation (no SKILL body cost) and
# additionally persists a `last_fetch_at` timestamp so subsequent mid-session
# "anything change?" checks via delta-check pass `updatedMin=last_fetch_at`
# to the API and return a small (~300 B) response when nothing has changed.
#
# Subcommands:
#   entry-fetch  — print today's remaining events, persist last_fetch_at
#   delta-check  — print events that have changed since last fetch (or "no changes")
#   reset        — clear persisted state
#
# State file: $VAULT_PATH/_shared/calendar-sync-state.json
#   { "last_fetch_at": "2026-05-26T10:30:00+02:00", "today_date": "2026-05-26" }
#
# Design note: an earlier draft used Google's syncToken mechanism, but
# `nextSyncToken` is only returned for queries WITHOUT `timeMin`/`timeMax`,
# which we need for "today's agenda". `updatedMin` works alongside time
# bounds and gives the same empty-response cheap-check behavior, so we use
# that instead. Spike measurements (2026-05-26): empty `updatedMin` response
# ~346 B; full agenda ~5 KB.

set -euo pipefail

HOME_DIR="$HOME"

FORGE_CONF="${FORGE_CONF_OVERRIDE:-$HOME_DIR/.claude/forge.conf}"
if [ ! -f "$FORGE_CONF" ]; then
  echo "[forge-calendar] ERROR: forge.conf not found at $FORGE_CONF" >&2
  exit 1
fi
VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
if [ -z "$VAULT_PATH" ]; then
  echo "[forge-calendar] ERROR: VAULT_PATH not set in $FORGE_CONF" >&2
  exit 1
fi

STATE_FILE="$VAULT_PATH/_shared/calendar-sync-state.json"
WELLNESS_PREFS="$VAULT_PATH/_shared/wellness-preferences.json"
[ -f "$WELLNESS_PREFS" ] || WELLNESS_PREFS="$HOME_DIR/.claude/wellness-preferences.json"

check_calendar_enabled() {
  # Exit 0 if calendar_enabled: true in wellness-preferences.json. Exit 1 otherwise.
  [ -f "$WELLNESS_PREFS" ] || return 1
  WP="$WELLNESS_PREFS" python3 -c "
import json, os, sys
try:
    d = json.load(open(os.environ['WP']))
    sys.exit(0 if d.get('calendar_enabled') else 1)
except Exception:
    sys.exit(1)
"
}

now_eod_today() {
  # Print three lines: ISO now, ISO end-of-day, YYYY-MM-DD today
  python3 -c '
import datetime
now = datetime.datetime.now().astimezone()
eod = now.replace(hour=23, minute=59, second=59, microsecond=0)
print(now.isoformat())
print(eod.isoformat())
print(now.strftime("%Y-%m-%d"))
'
}

gws_list_events() {
  # Call `gws calendar events list` with the params JSON passed as arg1.
  # Captures stdout (JSON) cleanly; on failure, surfaces stderr for diagnostics.
  # Returns 0 + prints JSON on success; non-zero otherwise (caller checks).
  local params="$1"
  local resp errfile rc
  errfile=$(mktemp)
  if resp=$(gws calendar events list --params "$params" 2>"$errfile"); then
    rm -f "$errfile"
    printf '%s' "$resp"
    return 0
  fi
  rc=$?
  echo "[forge-calendar] gws call failed: $(cat "$errfile")" >&2
  rm -f "$errfile"
  return "$rc"
}

print_events_and_save_state() {
  # arg1 = raw JSON response; arg2 = mode ("agenda" prints all today; "delta"
  # prints only changes with a re-fetch hint). Saves last_fetch_at + today_date.
  RESP="$1" MODE="$2" STATE_FILE="$STATE_FILE" python3 - <<'PYEOF'
import json, os, sys, datetime
raw = os.environ['RESP']
mode = os.environ['MODE']
state_file = os.environ['STATE_FILE']
try:
    resp = json.loads(raw)
except json.JSONDecodeError:
    print(f"[forge-calendar] non-JSON response (auth issue?): {raw[:200]}", file=sys.stderr)
    sys.exit(2)

items = resp.get('items', [])
def fmt(e):
    self_attendee = next((a for a in e.get('attendees', []) if a.get('self')), None)
    if self_attendee and self_attendee.get('responseStatus') == 'declined':
        return None
    start = e.get('start', {})
    if 'dateTime' in start:
        when = start['dateTime'].split('T')[1][:5]
    elif 'date' in start:
        when = 'all-day'
    else:
        when = '?'
    title = e.get('summary', '(no title)')
    location = e.get('location', '')
    loc_str = f"  @ {location}" if location else ''
    return f"  {when}  {title}{loc_str}"

if mode == 'agenda':
    shown = 0
    for e in items:
        line = fmt(e)
        if line:
            print(line)
            shown += 1
    if shown == 0:
        print("  (no remaining events today)")
elif mode == 'delta':
    shown = 0
    for e in items:
        status = e.get('status', '?')
        line = fmt(e)
        if line:
            print(f"  [{status}]{line}")
            shown += 1
    if shown == 0:
        print("# no calendar changes since last check")
    else:
        print(f"# {shown} change(s) above — re-run entry-fetch for fresh agenda")

now_iso = datetime.datetime.now().astimezone().isoformat()
today = datetime.datetime.now().astimezone().strftime("%Y-%m-%d")
state = {'last_fetch_at': now_iso, 'today_date': today}
os.makedirs(os.path.dirname(state_file), exist_ok=True)
with open(state_file, 'w') as f:
    json.dump(state, f, indent=2)
PYEOF
}

do_entry_fetch() {
  if ! check_calendar_enabled; then
    echo "[forge-calendar] calendar disabled (or wellness-preferences.json missing) — skipping" >&2
    return 0
  fi

  local now_iso eod_iso today
  { read -r now_iso; read -r eod_iso; read -r today; } < <(now_eod_today)

  local params
  params=$(NOW="$now_iso" EOD="$eod_iso" python3 -c "
import json, os
print(json.dumps({
  'calendarId': 'primary',
  'timeMin': os.environ['NOW'],
  'timeMax': os.environ['EOD'],
  'singleEvents': True,
  'orderBy': 'startTime',
  'maxResults': 20,
}))")

  local resp
  resp=$(gws_list_events "$params") || return $?
  print_events_and_save_state "$resp" "agenda"
}

do_delta_check() {
  if ! check_calendar_enabled; then
    echo "[forge-calendar] calendar disabled — skipping" >&2
    return 0
  fi

  if [ ! -f "$STATE_FILE" ]; then
    echo "[forge-calendar] no saved state — run 'forge-calendar.sh entry-fetch' first" >&2
    return 1
  fi

  local last_fetch today
  { read -r last_fetch; read -r today; } < <(SF="$STATE_FILE" python3 -c "
import json, os
d = json.load(open(os.environ['SF']))
print(d['last_fetch_at'])
print(d['today_date'])
")

  # If the saved state is from a previous day, the agenda is stale — caller
  # should re-run entry-fetch instead of a delta.
  local current_today
  current_today=$(date +%Y-%m-%d)
  if [ "$today" != "$current_today" ]; then
    echo "[forge-calendar] saved state is from $today, today is $current_today — run entry-fetch" >&2
    return 1
  fi

  local now_iso eod_iso _today
  { read -r now_iso; read -r eod_iso; read -r _today; } < <(now_eod_today)

  local params
  params=$(NOW="$now_iso" EOD="$eod_iso" UPD="$last_fetch" python3 -c "
import json, os
print(json.dumps({
  'calendarId': 'primary',
  'timeMin': os.environ['NOW'],
  'timeMax': os.environ['EOD'],
  'updatedMin': os.environ['UPD'],
  'singleEvents': True,
  'orderBy': 'startTime',
  'maxResults': 20,
  'showDeleted': True,
}))")

  local resp
  resp=$(gws_list_events "$params") || return $?
  print_events_and_save_state "$resp" "delta"
}

do_reset() {
  if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    echo "[forge-calendar] state cleared: $STATE_FILE"
  else
    echo "[forge-calendar] no state to clear"
  fi
}

do_next_meeting() {
  # Print the next non-declined meeting starting within $1 minutes, or nothing.
  # Output format (single line): HH:MM|title|minutes_until
  # Silent (no output, exit 0) when calendar disabled, no events in window,
  # or fetch fails — caller treats absence as "nothing imminent". Errors that
  # need surfacing go to stderr.
  local window_min="${1:-30}"
  if ! check_calendar_enabled; then
    return 0
  fi

  local now_iso end_iso
  { read -r now_iso; read -r end_iso; } < <(WIN="$window_min" python3 -c "
import datetime, os
win = int(os.environ['WIN'])
now = datetime.datetime.now().astimezone()
end = now + datetime.timedelta(minutes=win)
print(now.isoformat())
print(end.isoformat())
")

  local params
  params=$(NOW="$now_iso" END="$end_iso" python3 -c "
import json, os
print(json.dumps({
  'calendarId': 'primary',
  'timeMin': os.environ['NOW'],
  'timeMax': os.environ['END'],
  'singleEvents': True,
  'orderBy': 'startTime',
  'maxResults': 5,
}))")

  local resp
  resp=$(gws_list_events "$params") || return 0

  RESP="$resp" NOW_ISO="$now_iso" python3 - <<'PYEOF'
import json, os, sys, datetime
raw = os.environ['RESP']
now_iso = os.environ['NOW_ISO']
try:
    resp = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

now = datetime.datetime.fromisoformat(now_iso)
for e in resp.get('items', []):
    self_attendee = next((a for a in e.get('attendees', []) if a.get('self')), None)
    if self_attendee and self_attendee.get('responseStatus') == 'declined':
        continue
    start = e.get('start', {})
    if 'dateTime' not in start:
        continue
    try:
        start_dt = datetime.datetime.fromisoformat(start['dateTime'])
    except ValueError:
        continue
    minutes_until = int((start_dt - now).total_seconds() // 60)
    if minutes_until < 0:
        continue
    hh_mm = start['dateTime'].split('T')[1][:5]
    title = e.get('summary', '(no title)').replace('|', '/')
    print(f"{hh_mm}|{title}|{minutes_until}")
    break
PYEOF
}

do_in_meeting() {
  # Print the currently-in-progress (non-declined) meeting, or nothing.
  # Output format (single line): title|minutes_remaining
  # Silent (no output, exit 0) when calendar disabled, no event spans now,
  # or fetch fails — caller treats absence as "user is free right now".
  #
  # Distinct from next-meeting which only reports UPCOMING events
  # (skips events with negative minutes_until). This subcommand is the
  # in-progress counterpart, used by wellness-timer.py to defer real-break
  # nags + strikes when the user is mid-meeting (can't act on a nag).
  #
  # Implementation: query a wider time window (now-3h to now+1min) to catch
  # events that started up to 3h ago, then filter in Python on
  # start.dateTime <= now <= end.dateTime. Three hours is the realistic
  # maximum meeting length on the user's calendar; longer events
  # (workshops, off-sites) would benefit from explicit "DND" instead of
  # auto-defer anyway.
  if ! check_calendar_enabled; then
    return 0
  fi

  local now_iso start_iso end_iso
  { read -r now_iso; read -r start_iso; read -r end_iso; } < <(python3 -c "
import datetime
now = datetime.datetime.now().astimezone()
print(now.isoformat())
print((now - datetime.timedelta(hours=3)).isoformat())
print((now + datetime.timedelta(minutes=1)).isoformat())
")

  local params
  params=$(START="$start_iso" END="$end_iso" python3 -c "
import json, os
print(json.dumps({
  'calendarId': 'primary',
  'timeMin': os.environ['START'],
  'timeMax': os.environ['END'],
  'singleEvents': True,
  'orderBy': 'startTime',
  'maxResults': 10,
}))")

  local resp
  resp=$(gws_list_events "$params") || return 0

  RESP="$resp" NOW_ISO="$now_iso" python3 - <<'PYEOF'
import json, os, sys, datetime
raw = os.environ['RESP']
now_iso = os.environ['NOW_ISO']
try:
    resp = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

now = datetime.datetime.fromisoformat(now_iso)
for e in resp.get('items', []):
    self_attendee = next((a for a in e.get('attendees', []) if a.get('self')), None)
    if self_attendee and self_attendee.get('responseStatus') == 'declined':
        continue
    start = e.get('start', {})
    end = e.get('end', {})
    if 'dateTime' not in start or 'dateTime' not in end:
        continue
    try:
        start_dt = datetime.datetime.fromisoformat(start['dateTime'])
        end_dt = datetime.datetime.fromisoformat(end['dateTime'])
    except ValueError:
        continue
    if not (start_dt <= now <= end_dt):
        continue
    minutes_remaining = int((end_dt - now).total_seconds() // 60)
    if minutes_remaining < 0:
        continue
    title = e.get('summary', '(no title)').replace('|', '/')
    print(f"{title}|{minutes_remaining}")
    break
PYEOF
}

case "${1:-}" in
  entry-fetch) do_entry_fetch ;;
  delta-check) do_delta_check ;;
  next-meeting) shift; do_next_meeting "${1:-30}" ;;
  in-meeting)  do_in_meeting ;;
  reset)       do_reset ;;
  *)
    echo "Usage: forge-calendar.sh {entry-fetch|delta-check|next-meeting [window_min]|in-meeting|reset}" >&2
    exit 1
    ;;
esac
