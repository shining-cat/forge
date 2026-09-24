#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
if [ -f "$HOME/.claude/scripts/forge_capability/cli.py" ]; then CLI=(python3 "$HOME/.claude/scripts/forge_capability/cli.py"); else CLI=(env PYTHONPATH="$ROOT/core" python3 -m model_catalog.cli); fi
case "${1:-resolve}" in
  resolve)
    [ "${1:-}" = resolve ] && shift
    role=""
    if [ "${1:-}" != "" ] && [[ "${1:-}" != -* ]]; then role="$1"; shift; fi
    snapshot="${VAULT_PATH:?VAULT_PATH is required}/_shared/capability-snapshot.json"
    config="${FORGE_CONF:-$HOME/.claude/forge.conf}"
    if [ -n "$role" ]; then
      exec "${CLI[@]}" resolve --snapshot "$snapshot" --role "$role" --config "$config" "$@"
    fi
    exec "${CLI[@]}" resolve --snapshot "$snapshot" --config "$config" "$@" ;;
  publish|migrate) exec "${CLI[@]}" "$@" ;;
  *) exec "${CLI[@]}" resolve --snapshot "${VAULT_PATH:?VAULT_PATH is required}/_shared/capability-snapshot.json" "$@" ;;
esac
