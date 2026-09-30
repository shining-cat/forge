#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
if [ -f "$COPILOT_DIR/scripts/model_catalog/cli.py" ]; then CLI=(python3 "$COPILOT_DIR/scripts/model_catalog/cli.py"); else CLI=(env PYTHONPATH="$ROOT/core" python3 -m model_catalog.cli); fi
require_local_binding() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --binding)
        shift
        if [ "${1:-}" != copilot-cli ]; then
          echo '{"status":"invalid","error":"Copilot catalog binding must be copilot-cli"}'
          return 3
        fi ;;
      --binding=*)
        if [ "${1#--binding=}" != copilot-cli ]; then
          echo '{"status":"invalid","error":"Copilot catalog binding must be copilot-cli"}'
          return 3
        fi ;;
    esac
    shift
  done
}
case "${1:-resolve}" in
  resolve)
    [ "${1:-}" = resolve ] && shift
    role=""
    if [ "${1:-}" != "" ] && [[ "${1:-}" != -* ]]; then role="$1"; shift; fi
    : "${VAULT_PATH:?VAULT_PATH is required}"
    config="${FORGE_CONF:-$COPILOT_DIR/forge.conf}"
    require_local_binding "$@"
    if [ -n "$role" ]; then
      exec "${CLI[@]}" resolve --role "$role" --config "$config" "$@" --binding copilot-cli
    fi
    exec "${CLI[@]}" resolve --config "$config" "$@" --binding copilot-cli ;;
  finish-onboarding)
    args=("$@")
    binding=""
    config=""
    for ((i=1; i<${#args[@]}; i++)); do
      case "${args[i]}" in
        --binding) binding="${args[i+1]:-}"; i=$((i+1)) ;;
        --binding=*) binding="${args[i]#--binding=}" ;;
        --config) config="${args[i+1]:-}"; i=$((i+1)) ;;
        --config=*) config="${args[i]#--config=}" ;;
      esac
    done
    if [ "$binding" != copilot-cli ] || [ "$config" != "${FORGE_CONF:-$COPILOT_DIR/forge.conf}" ]; then
      echo "Error: Copilot onboarding requires the Copilot runtime and config" >&2
      exit 2
    fi
    exec "${CLI[@]}" "${args[@]}" ;;
  check-coverage|onboarding-status)
    command="$1"; shift
    require_local_binding "$@"
    exec "${CLI[@]}" "$command" "$@" --binding copilot-cli ;;
  publish|migrate) exec "${CLI[@]}" "$@" ;;
  *) : "${VAULT_PATH:?VAULT_PATH is required}"; require_local_binding "$@"; exec "${CLI[@]}" resolve --config "${FORGE_CONF:-$COPILOT_DIR/forge.conf}" "$@" --binding copilot-cli ;;
esac
