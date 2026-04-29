#!/bin/bash
# Forge Installer — copies Forge components into ~/.claude/ and wires hooks/permissions
#
# Usage: ./install.sh [--vault-path PATH] [--dry-run]
#
# Options:
#   --vault-path PATH  Set vault location (default: ~/Vault)
#   --dry-run          Show what would be done without changing anything
#
# Idempotent: safe to re-run after updates (git pull && ./install.sh)

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

info()  { printf "${CYAN}[forge]${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}  ✓${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}  !${NC} %s\n" "$1"; }
fail()  { printf "${RED}  ✗${NC} %s\n" "$1"; exit 1; }
hint()  { printf "${DIM}    %s${NC}\n" "$1"; }

# ─── Parse arguments ─────────────────────────────────────────────────────────
VAULT_PATH=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --vault-path) VAULT_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,/^$/s/^# //p' "$0"
      exit 0
      ;;
    *) fail "Unknown option: $1" ;;
  esac
done

# Dry-run helper: prints the command instead of running it
run() {
  if [ "$DRY_RUN" = true ]; then
    printf "${DIM}    would run: %s${NC}\n" "$*"
  else
    "$@"
  fi
}

# ─── Detect repo root ────────────────────────────────────────────────────────
FORGE_ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$FORGE_ROOT/core" ] || [ ! -d "$FORGE_ROOT/adapters/claude-code" ]; then
  fail "Can't find Forge repo structure. Run this from the forge repo root."
fi

echo ""
if [ "$DRY_RUN" = true ]; then
  printf "${YELLOW}[forge] DRY RUN — no files will be modified${NC}\n"
fi
info "Installing Forge from $FORGE_ROOT"
echo ""

# ─── Prerequisites ───────────────────────────────────────────────────────────
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
PREREQ_FAILED=false
WARNINGS=""

info "Checking prerequisites..."

# --- Hard requirements (fail without these) ---

if [ ! -d "$CLAUDE_DIR" ]; then
  fail "~/.claude/ not found — Claude Code must be installed first."
fi
ok "Claude Code"

if ! command -v git &>/dev/null; then
  fail "git not found."
fi
ok "git"

if ! command -v jq &>/dev/null; then
  fail "jq not found — required by Forge hooks and scripts."
  hint "Install: brew install jq"
fi
ok "jq"

# --- Warn but continue ---

if ! command -v python3 &>/dev/null; then
  warn "python3 not found — wellness coach module will not work."
  hint "Install: brew install python3"
else
  ok "python3"
fi

if [ -f "$SETTINGS_FILE" ]; then
  if jq -e '.enabledPlugins | keys[] | select(startswith("superpowers@"))' "$SETTINGS_FILE" &>/dev/null 2>&1; then
    ok "superpowers plugin"
  else
    warn "superpowers plugin not found — Forge requires it for process discipline."
    hint "Install: https://github.com/obra/superpowers-marketplace"
    hint "Then add to Claude Code plugins."
  fi
fi

# --- Inform only ---

if command -v open &>/dev/null && mdfind "kMDItemCFBundleIdentifier == 'md.obsidian'" 2>/dev/null | grep -q .; then
  ok "Obsidian (for vault browsing)"
else
  hint "Obsidian recommended for browsing the vault — https://obsidian.md"
  hint "Not required — the vault is plain markdown files."
fi

if command -v terminal-notifier &>/dev/null; then
  ok "terminal-notifier (for approval notifications)"
else
  hint "terminal-notifier recommended for macOS notifications on approval prompts."
  hint "Install: brew install terminal-notifier"
fi

echo ""

# ─── Vault path ──────────────────────────────────────────────────────────────
if [ -z "$VAULT_PATH" ]; then
  FORGE_CONF="$CLAUDE_DIR/forge.conf"
  if [ -f "$FORGE_CONF" ]; then
    EXISTING_VAULT=$(grep '^VAULT_PATH=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- || true)
    if [ -n "$EXISTING_VAULT" ]; then
      VAULT_PATH="$EXISTING_VAULT"
      info "Using existing vault path: $VAULT_PATH"
    fi
  fi
fi

if [ -z "$VAULT_PATH" ]; then
  VAULT_PATH="$HOME/Vault"
  if [ "$DRY_RUN" = true ]; then
    info "Would prompt for vault location (default: $VAULT_PATH)"
  else
    printf "${CYAN}[forge]${NC} Where should the vault live? [%s]: " "$VAULT_PATH"
    read -r custom_path
    if [ -n "$custom_path" ]; then
      VAULT_PATH="${custom_path/#\~/$HOME}"
    fi
  fi
fi

# Expand ~ if present
VAULT_PATH="${VAULT_PATH/#\~/$HOME}"

# Write forge.conf
if [ "$DRY_RUN" = true ]; then
  ok "forge.conf would be written (vault: $VAULT_PATH)"
else
  cat > "$CLAUDE_DIR/forge.conf" <<EOF
# Forge configuration — written by install.sh
VAULT_PATH=$VAULT_PATH
FORGE_REPO=$FORGE_ROOT
ONBOARDING_COMPLETE=false
WELLNESS_ENABLED=false

# Model assignments per role — valid values: opus, sonnet, haiku
# Empty value = inherit from session model
MODEL_KEEPER=sonnet
MODEL_REFINER=opus
MODEL_REVIEWER=sonnet
MODEL_IMPL=
MODEL_ARCHITECT=opus
MODEL_DEBUGGER=opus
MODEL_RELEASE=sonnet
MODEL_TOOLSMITH=opus
EOF
  ok "forge.conf written (vault: $VAULT_PATH)"
fi

# ─── Create vault structure ──────────────────────────────────────────────────
echo ""
info "Setting up vault..."

run mkdir -p "$VAULT_PATH/_shared/tasks/open" \
             "$VAULT_PATH/_shared/tasks/resolved" \
             "$VAULT_PATH/_shared/decisions" \
             "$VAULT_PATH/_templates" \
             "$VAULT_PATH/_meta"

run cp "$FORGE_ROOT/core/vault-templates/"* "$VAULT_PATH/_templates/"
ok "Vault structure at $VAULT_PATH"

# ─── Copy skills ─────────────────────────────────────────────────────────────
ADAPTER="$FORGE_ROOT/adapters/claude-code"
SKILLS_DIR="$CLAUDE_DIR/skills"

echo ""
info "Installing skills..."

# Core skills
for skill in forge forge-checkpoint forge-exit keeper refiner plan-reviewer; do
  run mkdir -p "$SKILLS_DIR/$skill"
  run cp "$ADAPTER/skills/$skill/SKILL.md" "$SKILLS_DIR/$skill/SKILL.md"
done
ok "Core skills (forge, forge-checkpoint, forge-exit, keeper, refiner, plan-reviewer)"

# Symlink core references into forge skill
run mkdir -p "$SKILLS_DIR/forge/references"
for ref in lifecycle.md vocabulary.md wellness-awareness.md; do
  run rm -f "$SKILLS_DIR/forge/references/$ref"
  run ln -s "$FORGE_ROOT/core/references/$ref" "$SKILLS_DIR/forge/references/$ref"
done
ok "References symlinked (updates with git pull)"

# Wellness coach files (always copied — hooks wired during onboarding)
WC_SRC="$ADAPTER/modules/wellness-coach"
WC_DST="$SKILLS_DIR/wellness-coach"

run mkdir -p "$WC_DST/hooks" "$WC_DST/scripts" "$WC_DST/src"
run cp "$WC_SRC/skills/wellness-coach/SKILL.md" "$WC_DST/SKILL.md"
run cp "$WC_SRC/README.md" "$WC_DST/"
run cp "$WC_SRC/hooks/"*.py "$WC_DST/hooks/"
run cp "$WC_SRC/scripts/"* "$WC_DST/scripts/"
run cp "$WC_SRC/src/screen_state.c" "$WC_DST/src/"
run chmod +x "$WC_DST/scripts/"*.sh
ok "Wellness coach files (activation offered during first /forge session)"

# ─── Copy hooks & scripts ────────────────────────────────────────────────────
echo ""
info "Installing hooks and scripts..."

run mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/scripts"

run cp "$ADAPTER/hooks/forge-compaction.sh" "$CLAUDE_DIR/hooks/"
run cp "$ADAPTER/hooks/approval-notifier.sh" "$CLAUDE_DIR/hooks/"
run cp "$ADAPTER/scripts/forge-context.sh" "$CLAUDE_DIR/scripts/"
run cp "$ADAPTER/scripts/statusline.sh" "$CLAUDE_DIR/statusline.sh"

run chmod +x "$CLAUDE_DIR/hooks/forge-compaction.sh" \
             "$CLAUDE_DIR/hooks/approval-notifier.sh" \
             "$CLAUDE_DIR/scripts/forge-context.sh" \
             "$CLAUDE_DIR/statusline.sh"

ok "Hooks and scripts installed"

# ─── Merge settings.json ─────────────────────────────────────────────────────
echo ""
info "Configuring settings.json..."

if [ ! -f "$SETTINGS_FILE" ]; then
  if [ "$DRY_RUN" = true ]; then
    ok "settings.json not found — would create empty"
    SETTINGS='{}'
  else
    echo '{}' > "$SETTINGS_FILE"
  fi
fi

# Backup
if [ "$DRY_RUN" = false ]; then
  cp "$SETTINGS_FILE" "$SETTINGS_FILE.forge-backup"
fi

# ── Permissions ──
PERMS_TO_ADD=(
  'Bash(*forge-context.sh*)'
)

SETTINGS=$(cat "$SETTINGS_FILE")
for perm in "${PERMS_TO_ADD[@]}"; do
  if ! echo "$SETTINGS" | jq -e ".permissions.allow // [] | index(\"$perm\")" &>/dev/null; then
    SETTINGS=$(echo "$SETTINGS" | jq ".permissions.allow = ((.permissions.allow // []) + [\"$perm\"])")
  fi
done
ok "Permissions"

# ── Hooks ──
# Helper: add a hook entry if its command doesn't already exist in the event
add_hook() {
  local event="$1" matcher="$2" command="$3" timeout="${4:-5}"
  local settings="$5"

  if echo "$settings" | jq -e ".hooks.\"$event\" // [] | .. | .command? // empty | select(. == \"$command\")" &>/dev/null 2>&1; then
    echo "$settings"
    return
  fi

  local hook_obj
  if [ "$matcher" = "null" ]; then
    hook_obj=$(jq -n --arg cmd "$command" --argjson t "$timeout" \
      '{hooks: [{type: "command", command: $cmd, timeout: $t}]}')
  else
    hook_obj=$(jq -n --arg m "$matcher" --arg cmd "$command" --argjson t "$timeout" \
      '{matcher: $m, hooks: [{type: "command", command: $cmd, timeout: $t}]}')
  fi

  echo "$settings" | jq --argjson h "$hook_obj" ".hooks.\"$event\" = ((.hooks.\"$event\" // []) + [\$h])"
}

# Core hooks only — wellness hooks are wired during onboarding
SETTINGS=$(add_hook "PreToolUse" "null" "$HOME/.claude/hooks/approval-notifier.sh" 5 "$SETTINGS")
SETTINGS=$(add_hook "PreToolUse" "Bash" "$HOME/.claude/scripts/forge-context.sh gate" 5 "$SETTINGS")
SETTINGS=$(add_hook "PreCompact" "null" "$HOME/.claude/hooks/forge-compaction.sh pre" 10 "$SETTINGS")
SETTINGS=$(add_hook "PostCompact" "null" "$HOME/.claude/hooks/forge-compaction.sh post" 10 "$SETTINGS")
SETTINGS=$(add_hook "PostToolUse" "null" "$HOME/.claude/scripts/forge-context.sh post-tool" 5 "$SETTINGS")
SETTINGS=$(add_hook "Stop" "null" "$HOME/.claude/scripts/forge-context.sh stop" 5 "$SETTINGS")
ok "Hooks (6 core hooks)"

# ── Statusline ──
SETTINGS=$(echo "$SETTINGS" | jq '.statusLine = {type: "command", command: "~/.claude/statusline.sh", padding: 0}')
ok "Statusline"

# Write back
if [ "$DRY_RUN" = true ]; then
  # Show what would change
  HOOKS_COUNT=$(echo "$SETTINGS" | jq '[.hooks | to_entries[] | .value[]] | length')
  PERMS_COUNT=$(echo "$SETTINGS" | jq '[.permissions.allow // [] | .[]] | length')
  ok "settings.json would be updated ($HOOKS_COUNT hook entries, $PERMS_COUNT permissions)"
else
  echo "$SETTINGS" | jq '.' > "$SETTINGS_FILE"
  ok "settings.json updated (backup: settings.json.forge-backup)"
fi

# ─── Patch vault paths in SKILL.md files ──────────────────────────────────────
VAULT_REL="${VAULT_PATH/#$HOME\//}"

echo ""
info "Patching vault paths in skills..."

if [ "$DRY_RUN" = true ]; then
  # Count how many files would be patched
  PATCH_COUNT=0
  for skill_file in "$ADAPTER"/skills/*/SKILL.md; do
    if grep -q '{{VAULT}}' "$skill_file" 2>/dev/null; then
      PATCH_COUNT=$((PATCH_COUNT + 1))
    fi
  done
  ok "Would patch {{VAULT}} → $VAULT_REL in $PATCH_COUNT skill files"
else
  for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if grep -q '{{VAULT}}' "$skill_file" 2>/dev/null; then
      sed -i '' "s|{{VAULT}}|$VAULT_REL|g" "$skill_file"
    fi
  done
  ok "Vault paths set to $VAULT_REL"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$DRY_RUN" = true ]; then
  printf "${YELLOW}  Dry run complete — no files were modified.${NC}\n"
else
  printf "${GREEN}  Forge installed successfully.${NC}\n"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Core skills:   forge, forge-checkpoint, forge-exit,"
echo "                 keeper, refiner, plan-reviewer"
echo "  Wellness:      files ready — offered during onboarding"
echo "  Vault:         $VAULT_PATH"
echo "  Config:        ~/.claude/forge.conf"
echo "  Backup:        ~/.claude/settings.json.forge-backup"
echo ""
echo "  Next step:     type /forge in Claude Code to start"
echo ""
echo "  Dependencies:"
echo "    Required:    superpowers"
hint "https://github.com/obra/superpowers-marketplace"
echo "    Recommended: code-review, commit-commands, pr-review-toolkit"
hint "Available from claude-plugins-official marketplace"
echo ""
