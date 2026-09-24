#!/usr/bin/env bash
# Forge runtime-neutral installer entry point.
#
# Usage: ./install.sh [--runtime claude|copilot] [runtime options...]
#
# With no --runtime, Claude Code remains the backward-compatible default.

set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="claude"

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Forge installer

Usage:
  ./install.sh [--runtime claude|copilot] [options]
  ./install.sh --claude [options]
  ./install.sh --copilot [options]

With no runtime selector, Claude Code is the default.
Runtime-specific installers are also available at:
  adapters/claude-code/install.sh
  adapters/copilot-cli/install.sh
EOF
    exit 0
    ;;
  --runtime)
    [[ $# -ge 2 ]] || {
      printf 'error: --runtime requires claude or copilot\n' >&2
      exit 2
    }
    RUNTIME="$2"
    shift 2
    ;;
  --claude)
    RUNTIME="claude"
    shift
    ;;
  --copilot)
    RUNTIME="copilot"
    shift
    ;;
esac

case "$RUNTIME" in
  claude)
    exec "$FORGE_ROOT/adapters/claude-code/install.sh" "$@"
    ;;
  copilot|copilot-cli)
    exec "$FORGE_ROOT/adapters/copilot-cli/install.sh" "$@"
    ;;
  *)
    printf 'error: unsupported runtime %q; choose claude or copilot\n' "$RUNTIME" >&2
    exit 2
    ;;
esac
