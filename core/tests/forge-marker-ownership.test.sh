#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)" || exit 1
cleanup() { rm -rf -- "$T"; }
trap cleanup EXIT
PASS=0; FAIL=0

check() {
  if [ "$1" -eq 0 ]; then PASS=$((PASS+1))
  else printf 'FAIL: %s — %s\n' "$adapter" "$2"; FAIL=$((FAIL+1)); fi
}

for adapter in copilot-cli claude-code; do
  home="$T/$adapter"
  runtime="$home/.claude"
  session_env=CLAUDE_CODE_SESSION_ID
  if [ "$adapter" = copilot-cli ]; then
    runtime="$home/.copilot"
    session_env=COPILOT_SESSION_ID
  fi
  vault="$home/vault"
  mkdir -p "$runtime/scripts" "$vault/_shared" "$vault/PERSO/forge"
  script="$ROOT/adapters/$adapter/scripts/forge-context.sh"
  hook="$ROOT/adapters/$adapter/hooks/forge-session-end.sh"
  ln -s "$script" "$runtime/scripts/forge-context.sh"
  conf="$runtime/forge.conf"
  printf 'VAULT_PATH=%s\n' "$vault" > "$conf"
  marker="$vault/_shared/forge-active"
  checkpoint="$vault/PERSO/forge/current-checkpoint.md"
  printf -- '---\nproject: forge\nsession: closed\n---\n' > "$home/checkpoint.before"
  owner='{"session_id":"owner","project":"forge","started_at":"x","tmux_pane":null}'

  runtime_env() {
    env -u COPILOT_SESSION_ID -u COPILOT_AGENT_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
      HOME="$home" COPILOT_HOME="$home/.copilot" FORGE_CONF_OVERRIDE="$conf" "$@"
  }
  reset_fixture() {
    printf '%s' "$1" > "$marker"
    cp "$home/checkpoint.before" "$checkpoint"
  }
  check_marker() {
    local label="$1" content="$2" expected="$3"
    reset_fixture "$content"
    cp "$marker" "$home/marker.before"
    runtime_env "$session_env=owner" bash -c 'source "$1"; session_owns_forge' \
      _ "$script" > "$home/helper.out" 2>&1
    [ "$?" -eq "$expected" ]; check $? "$label helper ownership"
    printf '{}' | runtime_env "$session_env=owner" bash "$hook" > "$home/hook.out" 2>&1
    check $? "$label actual SessionEnd exits cleanly"
    if [ "$expected" -eq 0 ]; then
      [ ! -s "$marker" ]; check $? "$label owner clears marker"
      grep -q 'via SessionEnd' "$checkpoint"; check $? "$label owner annotates checkpoint"
    else
      cmp -s "$marker" "$home/marker.before"; check $? "$label preserves marker bytes"
      cmp -s "$checkpoint" "$home/checkpoint.before"; check $? "$label preserves checkpoint bytes"
    fi
  }

  check_marker "matching owner" "$owner" 0
  check_marker "sibling" '{"session_id":"sibling","project":"forge"}' 1
  check_marker "empty marker owner" '{"session_id":"","project":"forge"}' 1
  check_marker "missing marker owner" '{"project":"forge"}' 1
  check_marker "null marker owner" '{"session_id":null,"project":"forge"}' 1
  check_marker "numeric marker owner" '{"session_id":42,"project":"forge"}' 1
  check_marker "boolean marker owner" '{"session_id":true,"project":"forge"}' 1
  check_marker "blank marker owner" '{"session_id":" \t ","project":"forge"}' 1
  check_marker "newline marker owner mismatch" '{"session_id":"owner\n","project":"forge"}' 1
  check_marker "malformed JSON" '{"session_id":' 1
  check_marker "JSON array" '[]' 1
  check_marker "JSON string" '"forge"' 1
  check_marker "JSON scalar" '42' 1
  check_marker "JSON null" 'null' 1
  check_marker "JSON stream" "$owner $owner" 1
  check_marker "legacy project" 'forge' 0
  check_marker "empty marker" '' 1
  check_marker "pending marker" '__pending__' 1

  for payload in '{}' '{"session_id":"owner"}' '{"session_id":"sibling"}' '{"session_id":"owner\n"}'; do
    reset_fixture "$owner"
    printf '%s' "$payload" | runtime_env bash "$hook" > "$home/hook.out" 2>&1
    check $? "payload $payload exits cleanly"
    if [ "$payload" = '{"session_id":"owner"}' ]; then
      [ ! -s "$marker" ]; check $? "payload owner clears marker"
      grep -q 'via SessionEnd' "$checkpoint"; check $? "payload owner annotates checkpoint"
    else
      [ "$(cat "$marker")" = "$owner" ]; check $? "missing/sibling payload preserves marker"
      cmp -s "$checkpoint" "$home/checkpoint.before"; check $? "missing/sibling payload preserves checkpoint"
    fi
  done
  if [ "$adapter" = copilot-cli ]; then
    for identity in owner sibling 'owner\n'; do
      reset_fixture "$owner"
      printf '{"sessionId":"%s"}' "$identity" | runtime_env bash "$hook" > "$home/hook.out" 2>&1
      check $? "native payload $identity exits cleanly"
      if [ "$identity" = owner ]; then
        [ ! -s "$marker" ]; check $? "native payload owner clears marker"
        grep -q 'via SessionEnd' "$checkpoint"; check $? "native payload owner annotates checkpoint"
      else
        [ "$(cat "$marker")" = "$owner" ]; check $? "native sibling preserves marker"
        cmp -s "$checkpoint" "$home/checkpoint.before"; check $? "native sibling preserves checkpoint"
      fi
    done
  fi

  reset_fixture "$owner"
  rm -f -- "$marker"
  printf '{}' | runtime_env "$session_env=owner" bash "$hook" > "$home/hook.out" 2>&1
  check $? "missing marker exits cleanly"
  [ ! -e "$marker" ]; check $? "missing marker remains absent"
  cmp -s "$checkpoint" "$home/checkpoint.before"; check $? "missing marker preserves checkpoint"

  activate() {
    if [ "$1" = __absent__ ]; then runtime_env "$script" set-marker active forge
    else runtime_env "$session_env=$1" "$script" set-marker active forge; fi
  }
  for identity in __absent__ '' $' \t '; do
    reset_fixture "$owner"
    cp "$marker" "$home/marker.before"
    activate "$identity" > "$home/activate.out" 2> "$home/activate.err"
    [ "$?" -ne 0 ]; check $? "absent/empty/blank identity rejects activation"
    grep -qi 'session' "$home/activate.err"; check $? "activation rejection explains session requirement"
    cmp -s "$marker" "$home/marker.before"; check $? "rejected activation preserves marker bytes"
    cmp -s "$checkpoint" "$home/checkpoint.before"; check $? "rejected activation preserves closed checkpoint"
    rm -f -- "$marker"
    activate "$identity" > "$home/activate.out" 2> "$home/activate.err"
    [ "$?" -ne 0 ]; check $? "absent-marker activation still rejects invalid identity"
    [ ! -e "$marker" ]; check $? "rejected activation does not create marker"
    cmp -s "$checkpoint" "$home/checkpoint.before"; check $? "absent-marker rejection preserves checkpoint"
  done
  activate owner > "$home/activate.out" 2> "$home/activate.err"
  check $? "valid identity activates"
  [ "$(jq -r '.session_id' "$marker")" = owner ]; check $? "activation records valid identity"
  grep -q '^session: open$' "$checkpoint"; check $? "valid activation reopens checkpoint"
  identity=$'owner"\\\n'
  activate "$identity" > "$home/activate.out" 2> "$home/activate.err"
  check $? "activation accepts nonblank identity without changing its bytes"
  jq -e --arg expected "$identity" '.session_id == $expected' "$marker" >/dev/null 2>&1
  check $? "activation serializes identity exactly as JSON"
  printf '{}' | runtime_env "$session_env=$identity" bash "$hook" > "$home/hook.out" 2>&1
  check $? "exact identity round-trip exits cleanly"
  [ ! -s "$marker" ]; check $? "exact identity round-trip performs owner cleanup"
done

printf 'Marker ownership: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
