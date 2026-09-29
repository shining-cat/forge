#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
if [ -f "$COPILOT_DIR/scripts/model_catalog/cli.py" ]; then CLI=(python3 "$COPILOT_DIR/scripts/model_catalog/cli.py"); else CLI=(env PYTHONPATH="$ROOT/core" python3 -m model_catalog.cli); fi
case "${1:-resolve}" in
  resolve)
    [ "${1:-}" = resolve ] && shift
    role=""
    if [ "${1:-}" != "" ] && [[ "${1:-}" != -* ]]; then role="$1"; shift; fi
    : "${VAULT_PATH:?VAULT_PATH is required}"
    config="${FORGE_CONF:-$COPILOT_DIR/forge.conf}"
    if [ -n "$role" ]; then
      exec "${CLI[@]}" resolve --role "$role" --config "$config" --binding copilot-cli "$@"
    fi
    exec "${CLI[@]}" resolve --config "$config" --binding copilot-cli "$@" ;;
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
  publish|migrate|check-coverage|onboarding-status) exec "${CLI[@]}" "$@" ;;
  *) : "${VAULT_PATH:?VAULT_PATH is required}"; exec "${CLI[@]}" resolve --config "${FORGE_CONF:-$COPILOT_DIR/forge.conf}" --binding copilot-cli "$@" ;;
esac
