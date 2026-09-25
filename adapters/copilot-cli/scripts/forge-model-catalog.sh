#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
if [ -f "$HOME/.copilot/scripts/model_catalog/cli.py" ]; then CLI=(python3 "$HOME/.copilot/scripts/model_catalog/cli.py"); else CLI=(env PYTHONPATH="$ROOT/core" python3 -m model_catalog.cli); fi
case "${1:-resolve}" in
  resolve)
    [ "${1:-}" = resolve ] && shift
    role=""
    if [ "${1:-}" != "" ] && [[ "${1:-}" != -* ]]; then role="$1"; shift; fi
    : "${VAULT_PATH:?VAULT_PATH is required}"
    config="${FORGE_CONF:-$HOME/.copilot/forge.conf}"
    if [ -n "$role" ]; then
      exec "${CLI[@]}" resolve --role "$role" --config "$config" "$@"
    fi
    exec "${CLI[@]}" resolve --config "$config" "$@" ;;
  publish|migrate) exec "${CLI[@]}" "$@" ;;
  *) : "${VAULT_PATH:?VAULT_PATH is required}"; exec "${CLI[@]}" resolve "$@" ;;
esac
