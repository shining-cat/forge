#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
if [ -f "$HOME/.claude/scripts/forge_capability/cli.py" ]; then CLI=(python3 "$HOME/.claude/scripts/forge_capability/cli.py"); else CLI=(env PYTHONPATH="$ROOT/core" python3 -m model_catalog.cli); fi
case "${1:-resolve}" in
  resolve)
    [ "${1:-}" = resolve ] && shift
    role=""
    if [ "${1:-}" != "" ] && [[ "${1:-}" != -* ]]; then role="$1"; shift; fi
    : "${VAULT_PATH:?VAULT_PATH is required}"
    config="${FORGE_CONF:-$HOME/.claude/forge.conf}"
    if [ -n "$role" ]; then
      exec "${CLI[@]}" resolve --role "$role" --config "$config" --binding claude "$@"
    fi
    exec "${CLI[@]}" resolve --config "$config" --binding claude "$@" ;;
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
    if [ "$binding" != claude ] || [ "$config" != "${FORGE_CONF:-$HOME/.claude/forge.conf}" ]; then
      echo "Error: Claude onboarding requires the Claude runtime and config" >&2
      exit 2
    fi
    exec "${CLI[@]}" "${args[@]}" ;;
  publish|migrate|check-coverage|onboarding-status) exec "${CLI[@]}" "$@" ;;
  *) : "${VAULT_PATH:?VAULT_PATH is required}"; exec "${CLI[@]}" resolve --config "${FORGE_CONF:-$HOME/.claude/forge.conf}" --binding claude "$@" ;;
esac
