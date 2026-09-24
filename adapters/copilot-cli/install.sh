#!/usr/bin/env bash
# Forge installer — GitHub Copilot CLI adapter
#
# Usage: ./install.sh --runtime copilot [--vault-path PATH] [--dry-run|--preview]
#
# Installs the complete Copilot adapter into ${COPILOT_HOME:-$HOME/.copilot}.
# Runtime files are sourced from adapters/copilot-cli; no Claude adapter files
# are transformed during installation.

set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COPILOT_DIR="${COPILOT_HOME:-$HOME/.copilot}"
VAULT_PATH="$HOME/Vault"
DRY_RUN=false

info() { printf '[forge] %s\n' "$1"; }
warn() { printf '[forge] warning: %s\n' "$1" >&2; }
fail() { printf '[forge] error: %s\n' "$1" >&2; exit 1; }

usage() {
  sed -n '2,/^$/s/^# //p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-path)
      [[ $# -ge 2 ]] || fail "--vault-path requires a value"
      VAULT_PATH="$2"
      shift 2
      ;;
    --dry-run|--preview)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

ADAPTER="$FORGE_ROOT/adapters/copilot-cli"
[[ -d "$ADAPTER" ]] || fail "Copilot adapter not found at $ADAPTER"
[[ -d "$COPILOT_DIR" ]] || fail "$COPILOT_DIR not found; start Copilot CLI once and retry"

run() {
  if "$DRY_RUN"; then
    printf '  would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

copy_owned() {
  local source="$1" destination="$2"
  if "$DRY_RUN"; then
    printf '  would install %s -> %s\n' "$source" "$destination"
    return
  fi
  mkdir -p "$(dirname "$destination")"
  if [[ -f "$destination" ]] && ! cmp -s "$source" "$destination"; then
    cp "$destination" "$destination.pre-update.$(date +%Y%m%d-%H%M%S)"
  fi
  cp "$source" "$destination"
}

install_skill() {
  local source="$1" destination="$2" temporary
  if "$DRY_RUN"; then
    printf '  would install skill %s -> %s\n' "$source" "$destination"
    return
  fi
  mkdir -p "$(dirname "$destination")"
  temporary="$(mktemp)"
  sed "s|{{VAULT}}|$VAULT_PATH|g" "$source" > "$temporary"
  if [[ -f "$destination" ]] && ! cmp -s "$temporary" "$destination"; then
    cp "$destination" "$destination.pre-update.$(date +%Y%m%d-%H%M%S)"
  fi
  mv "$temporary" "$destination"
}

check_prerequisites() {
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  command -v git >/dev/null 2>&1 || fail "git is required"
  command -v python3 >/dev/null 2>&1 || warn "python3 is required only for wellness support"
}

check_prerequisites
info "Installing Copilot CLI adapter into $COPILOT_DIR"

for agent in "$ADAPTER/agents/"*.agent.md; do
  copy_owned "$agent" "$COPILOT_DIR/agents/$(basename "$agent")"
done

while IFS= read -r skill; do
  name="$(basename "$(dirname "$skill")")"
  install_skill "$skill" "$COPILOT_DIR/skills/$name/SKILL.md"
done < <(find "$ADAPTER/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -print | sort)

while IFS= read -r file; do
  relative="${file#"$ADAPTER/"}"
  case "$relative" in
    scripts/tests/*|modules/wellness-coach/*/tests/*) continue ;;
    scripts/*) copy_owned "$file" "$COPILOT_DIR/scripts/${relative#scripts/}" ;;
    hooks/forge.json) ;;
    hooks/*) copy_owned "$file" "$COPILOT_DIR/hooks/${relative#hooks/}" ;;
    references/*) copy_owned "$file" "$COPILOT_DIR/skills/forge/references/${relative#references/}" ;;
    modules/wellness-coach/skills/wellness-coach/SKILL.md)
      install_skill "$file" "$COPILOT_DIR/skills/wellness-coach/SKILL.md"
      ;;
    modules/wellness-coach/README.md)
      copy_owned "$file" "$COPILOT_DIR/skills/wellness-coach/README.md"
      ;;
    modules/wellness-coach/hooks/*)
      copy_owned "$file" "$COPILOT_DIR/skills/wellness-coach/hooks/$(basename "$file")"
      ;;
    modules/wellness-coach/scripts/*)
      copy_owned "$file" "$COPILOT_DIR/skills/wellness-coach/scripts/$(basename "$file")"
      ;;
    modules/wellness-coach/src/*)
      copy_owned "$file" "$COPILOT_DIR/skills/wellness-coach/src/$(basename "$file")"
      ;;
    modules/wellness-coach/references/*)
      copy_owned "$file" "$COPILOT_DIR/skills/wellness-coach/references/$(basename "$file")"
      ;;
  esac
done < <(find "$ADAPTER/scripts" "$ADAPTER/hooks" "$ADAPTER/modules/wellness-coach" "$ADAPTER/references" -type f -print | sort)

if ! "$DRY_RUN"; then
  find "$COPILOT_DIR/scripts" "$COPILOT_DIR/hooks" "$COPILOT_DIR/skills/wellness-coach" \
    -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
fi

if "$DRY_RUN"; then
  printf '  would merge %s -> %s\n' "$ADAPTER/hooks/forge.json" "$COPILOT_DIR/hooks/forge.json"
else
  mkdir -p "$COPILOT_DIR/hooks"
  if [[ -f "$COPILOT_DIR/hooks/forge.json" ]]; then
    cp "$COPILOT_DIR/hooks/forge.json" \
      "$COPILOT_DIR/hooks/forge.json.pre-update.$(date +%Y%m%d-%H%M%S)"
    merged="$(mktemp)"
    jq -s '
      .[0] as $existing |
      .[1] as $forge |
      ($existing.hooks // {}) as $existing_hooks |
      ($forge.hooks // {}) as $forge_hooks |
      $existing
      | .hooks = (
          ($existing_hooks
           | reduce ($forge_hooks | keys[]) as $event
               (.;
                .[$event] =
                  ((($existing_hooks[$event] // [])
                    | map(select(
                        ((.bash // "") | contains("/hooks/forge-") or
                         contains("/scripts/forge-") or
                         contains("copilot-")) | not)))
                   + $forge_hooks[$event]))
          )
        )
    ' "$COPILOT_DIR/hooks/forge.json" "$ADAPTER/hooks/forge.json" > "$merged"
    mv "$merged" "$COPILOT_DIR/hooks/forge.json"
  else
    cp "$ADAPTER/hooks/forge.json" "$COPILOT_DIR/hooks/forge.json"
  fi
fi

if [[ ! -f "$COPILOT_DIR/forge.conf" ]]; then
  if "$DRY_RUN"; then
    printf '  would create %s/forge.conf\n' "$COPILOT_DIR"
  else
    cat > "$COPILOT_DIR/forge.conf" <<EOF
VAULT_PATH=$VAULT_PATH
ONBOARDING_COMPLETE=false
RUNTIME=copilot-cli
EOF
  fi
fi

info "Copilot adapter installed. Restart Copilot CLI to load agents and hooks."
