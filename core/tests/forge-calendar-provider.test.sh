#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d "$ROOT/.calendar-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/vault/_shared" "$tmp/vault/PERSO/calendar-test" "$tmp/bin"
printf 'calendar-test\n' > "$tmp/vault/_shared/forge-active"
mkdir -p "$tmp/vault/_shared/wellness-coach"
printf '{"directory":"wellness-coach"}\n' > "$tmp/vault/_shared/wellness-location.json"
printf '{"calendar_enabled":true}\n' > "$tmp/vault/_shared/wellness-coach/wellness-preferences.json"
cat > "$tmp/bin/gws" <<'SH'
#!/bin/sh
printf 'called\n' >> "$CALENDAR_CALL_LOG"
case "$GWS_MODE" in
  success) printf '{"items":[]}\n' ;;
  auth) printf 'authentication failed\n' >&2; exit 37 ;;
  malformed) printf 'not-json\n' ;;
  api-error) printf '{"error":{"message":"authentication failed"}}\n' ;;
esac
SH
chmod +x "$tmp/bin/gws"
cat > "$tmp/bin/mktemp" <<'SH'
#!/bin/sh
exec /usr/bin/mktemp "$CALENDAR_TEST_DIR/scratch.XXXXXX"
SH
chmod +x "$tmp/bin/mktemp"
export CALENDAR_TEST_DIR="$tmp"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for adapter in claude-code copilot-cli; do
  script="$ROOT/adapters/$adapter/scripts/forge-calendar.sh"
  context="$ROOT/adapters/$adapter/scripts/forge-context.sh"
  if [ "$adapter" = claude-code ]; then install_dir="$tmp/home/.claude"; else install_dir="$tmp/home/.copilot"; fi
  mkdir -p "$install_dir/scripts" "$install_dir/skills/wellness-coach/hooks"
  ln -sf "$script" "$install_dir/scripts/forge-calendar.sh"
  ln -sf "$ROOT/adapters/$adapter/modules/wellness-coach/hooks/wellness_location.py" \
    "$install_dir/skills/wellness-coach/hooks/wellness_location.py"
  state="$tmp/vault/_shared/calendar-sync-state.json"
  calls="$tmp/calls"
  config="$tmp/forge.conf"
  run() {
    rc=0
    HOME="$tmp/home" COPILOT_HOME="$tmp/home/.copilot" \
      FORGE_CONF_OVERRIDE="$config" CALENDAR_CALL_LOG="$calls" \
      GWS_MODE="$mode" PATH="$tmp/bin:$PATH" bash "$script" "$@" \
      > "$tmp/out" 2> "$tmp/err" || rc=$?
  }
  run_context() {
    rc=0
    HOME="$tmp/home" COPILOT_HOME="$tmp/home/.copilot" \
      FORGE_CONF_OVERRIDE="$config" CALENDAR_CALL_LOG="$calls" \
      GWS_MODE="$mode" PATH="$tmp/bin:$PATH" bash "$context" next-meeting \
      > "$tmp/out" 2> "$tmp/err" || rc=$?
  }
  set_provider() {
    printf 'VAULT_PATH=%s\n' "$tmp/vault" > "$config"
    [ -z "$1" ] || printf 'CALENDAR_PROVIDER=%s\n' "$1" >> "$config"
  }
  mode=auth
  for provider in "" m365 unknown; do
    set_provider "$provider"
    rm -f "$calls" "$state"
    for command in entry-fetch delta-check next-meeting in-meeting; do
      run "$command"
      [ "$rc" -eq 0 ] || fail "$adapter $provider $command returned $rc"
      if [ "$command" = entry-fetch ] || [ "$command" = delta-check ]; then
        grep -q 'calendar not configured\|calendar unavailable' "$tmp/out" ||
          fail "$adapter $provider $command did not report unavailable"
      else
        [ ! -s "$tmp/out" ] || fail "$adapter $provider $command reported a meeting"
      fi
    done
    [ ! -e "$calls" ] && [ ! -e "$state" ] ||
      fail "$adapter $provider contacted Google or wrote calendar state"
    run_context
    [ "$rc" -eq 0 ] && [ ! -s "$tmp/out" ] && [ ! -e "$calls" ] ||
      fail "$adapter $provider context check contacted Google"
  done

  set_provider gws
  rm -f "$calls" "$state"
  run entry-fetch
  [ "$rc" -eq 37 ] && grep -q 'authentication failed' "$tmp/err" ||
    fail "$adapter configured auth failure was masked"
  [ ! -e "$state" ] || fail "$adapter saved state after failed fetch"
  run_context
  [ "$rc" -eq 37 ] && grep -q 'authentication failed' "$tmp/err" ||
    fail "$adapter context next-meeting masked configured auth failure (exit $rc): $(cat "$tmp/err")"

  mode=success
  run entry-fetch
  [ "$rc" -eq 0 ] && grep -q 'no remaining events today' "$tmp/out" &&
    [ -f "$state" ] && [ -s "$calls" ] ||
    fail "$adapter configured GWS fetch did not succeed"
  cp "$state" "$tmp/state-before"

  mode=auth
  for command in entry-fetch delta-check next-meeting in-meeting; do
    run "$command"
    [ "$rc" -eq 37 ] && grep -q 'authentication failed' "$tmp/err" ||
      fail "$adapter $command did not report configured GWS failure"
    cmp -s "$tmp/state-before" "$state" ||
      fail "$adapter $command modified state after failed fetch"
  done

  mode=malformed
  run entry-fetch
  [ "$rc" -eq 2 ] && cmp -s "$tmp/state-before" "$state" ||
    fail "$adapter accepted malformed GWS response"
  for command in next-meeting in-meeting; do
    run "$command"
    [ "$rc" -eq 2 ] || fail "$adapter $command masked malformed response"
  done
  mode=api-error
  for command in entry-fetch delta-check next-meeting in-meeting; do
    run "$command"
    [ "$rc" -eq 2 ] && grep -q 'invalid events response' "$tmp/err" &&
      cmp -s "$tmp/state-before" "$state" ||
      fail "$adapter $command accepted an API error as an empty calendar"
  done

  printf '{"calendar_enabled":false}\n' > "$tmp/vault/_shared/wellness-coach/wellness-preferences.json"
  rm -f "$calls"
  run entry-fetch
  [ "$rc" -eq 0 ] && [ ! -e "$calls" ] ||
    fail "$adapter disabled calendar contacted Google"
  printf '{"calendar_enabled":true}\n' > "$tmp/vault/_shared/wellness-coach/wellness-preferences.json"
  echo "PASS: $adapter calendar provider gating"
done
