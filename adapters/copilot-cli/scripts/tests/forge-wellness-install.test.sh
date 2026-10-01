#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
tmp="$(mktemp -d "$ROOT/.wellness-install-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" COPILOT_HOME="$tmp/copilot"
mkdir -p "$HOME/Library/LaunchAgents" "$COPILOT_HOME" "$tmp/vault/_shared" "$tmp/bin"
export WELLNESS_TEST_ROOT="$tmp"
cat > "$tmp/bin/mktemp" <<'SH'
#!/bin/sh
exec /usr/bin/mktemp "$WELLNESS_TEST_ROOT/scratch.XXXXXX"
SH
chmod +x "$tmp/bin/mktemp"
export PATH="$tmp/bin:$PATH"
printf 'VAULT_PATH=%s\nWELLNESS_ENABLED=true\n' "$tmp/vault" > "$COPILOT_HOME/forge.conf"
printf '{"wellness_onboarding_complete":false,"activity_monitor_enabled":false,"activity_monitor_installed":false}\n' \
  > "$tmp/vault/_shared/wellness-preferences.json"

"$ROOT/install.sh" --runtime copilot --vault-path "$tmp/vault" >/dev/null
"$ROOT/install.sh" --runtime copilot --vault-path "$tmp/vault" >/dev/null

hooks="$COPILOT_HOME/hooks/forge.json"
jq -e '
  (.hooks.PreToolUse | map(select((.bash // "") | contains("/wellness-timer.py"))) | length == 1) and
  (.hooks.PostToolUse | map(select((.bash // "") | contains("/wellness-timer.py"))) | length == 0) and
  (.hooks.Stop | map(select((.bash // "") | contains("/wellness-timer.py"))) | length == 1) and
  (.hooks.Stop[-1].bash | contains("/wellness-timer.py")) and
  (.hooks.PreCompact | map(select((.bash // "") | contains("/wellness-precompact.py"))) | length == 1)
' "$hooks" >/dev/null
grep -q '^WELLNESS_ENABLED=true$' "$COPILOT_HOME/forge.conf"
grep -Fq '"${COPILOT_HOME:-$HOME/.copilot}/skills/wellness-coach/scripts/install-monitor.sh"' \
  "$ROOT/adapters/copilot-cli/modules/wellness-coach/references/onboarding.md"

printf '%s\n' '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}' |
  python3 "$COPILOT_HOME/skills/wellness-coach/hooks/wellness-timer.py" > "$tmp/output"
test ! -s "$tmp/output"
printf '%s\n' '{"hook_event_name":"Stop"}' |
  python3 "$COPILOT_HOME/skills/wellness-coach/hooks/wellness-timer.py" > "$tmp/output"
test ! -s "$tmp/output"
python3 "$COPILOT_HOME/skills/wellness-coach/hooks/wellness-precompact.py" > "$tmp/output"
test ! -s "$tmp/output"

if "$COPILOT_HOME/skills/wellness-coach/scripts/wellness-status.sh" --diagnose > "$tmp/diagnose"; then
  echo "FAIL: unconfigured monitor reported healthy" >&2
  exit 1
fi
grep -q 'Interactive setup:.*incomplete' "$tmp/diagnose"
grep -q 'Wellness hooks:.*registered' "$tmp/diagnose"
# Consent and old-writer shutdown are simulated explicitly; no real vault is touched.
python3 "$COPILOT_HOME/skills/wellness-coach/hooks/wellness_location.py" prepare \
  --directory wellness-coach --consent --old-tooling-stopped >/dev/null
prefs="$tmp/vault/_shared/wellness-coach/wellness-preferences.json"

cat > "$tmp/bin/cc" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    printf '#!/bin/sh\nprintf "display=on,locked=0\\n"\n' > "$1"
    chmod +x "$1"
    exit 0
  fi
  shift
done
exit 1
SH
cat > "$tmp/bin/launchctl" <<'SH'
#!/usr/bin/env bash
case "$1" in
  bootout) exit 1 ;;
  bootstrap|print) exit 0 ;;
esac
exit 1
SH
chmod +x "$tmp/bin/cc" "$tmp/bin/launchctl"
PATH="$tmp/bin:$PATH" "$COPILOT_HOME/skills/wellness-coach/scripts/install-monitor.sh" > "$tmp/install-output"
grep -q 'sampler self-check passed' "$tmp/install-output"
test -x "$COPILOT_HOME/bin/screen_state"
test -x "$COPILOT_HOME/bin/idle-sampler.py"
grep -q "$COPILOT_HOME" "$HOME/Library/LaunchAgents/com.copilot.wellness-idle-sampler.plist"
grep -Fq "$tmp/vault/_shared/wellness-coach/wellness-idle-sampler.log" \
  "$HOME/Library/LaunchAgents/com.copilot.wellness-idle-sampler.plist"
jq -e '.activity_monitor_enabled == false and .activity_monitor_installed == false' \
  "$prefs" >/dev/null
printf '{"session_id":"test","project":"demo"}\n' > "$tmp/vault/_shared/forge-active"
jq '.wellness_onboarding_complete = true | .activity_monitor_installed = true' \
  "$prefs" \
  > "$tmp/prefs" && mv "$tmp/prefs" "$prefs"
python3 "$COPILOT_HOME/bin/idle-sampler.py"
jq -e --argjson now "$(date +%s)" 'length > 0 and .[-1].t > ($now - 60)' \
  "$tmp/vault/_shared/wellness-coach/wellness-idle-log.json" >/dev/null
cat > "$tmp/bin/sysctl" <<'SH'
#!/bin/sh
echo "{ sec = 1000000000, usec = 0 }"
SH
cat > "$tmp/bin/osascript" <<'SH'
#!/bin/sh
printf 'notified\n' >> "$NOTIFY_LOG"
exit 0
SH
chmod +x "$tmp/bin/sysctl" "$tmp/bin/osascript"
export NOTIFY_LOG="$tmp/notifications"
jq '.interruption_level = "suggest" | .calendar_enabled = false' \
  "$prefs" > "$tmp/prefs" &&
  mv "$tmp/prefs" "$prefs"
python3 - "$tmp/vault/_shared/wellness-coach/wellness-runtime.json" <<'PY'
import json
import sys
import time

past = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - 90 * 60))
with open(sys.argv[1], "w") as f:
    json.dump({"last_break_timestamp": past, "last_micro_break_timestamp": past,
               "last_reminder_timestamp": past, "strike_active": False}, f)
PY
printf '%s\n' '{"hook_event_name":"Stop"}' |
  PATH="$tmp/bin:$PATH" python3 "$COPILOT_HOME/skills/wellness-coach/hooks/wellness-timer.py" \
    > "$tmp/output"
jq -e '.decision == "block" and (.reason | contains("Send the following wellness message"))' \
  "$tmp/output" >/dev/null
test -s "$NOTIFY_LOG"
mkdir -p "$tmp/vault/PERSO/demo"
printf '%s\n' '{"hook_event_name":"Stop","stop_hook_active":true}' |
  "$COPILOT_HOME/scripts/forge-context.sh" stop > "$tmp/output"
test ! -s "$tmp/output"

echo "PASS: Copilot wellness hook wiring, setup gate, and monitor install"
