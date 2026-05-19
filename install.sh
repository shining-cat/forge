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

# Tracks how many user-modified files we backed up during this run.
# Surfaced in the final summary so the user sees the count + can find them.
BACKUP_COUNT=0

# safe_cp — backup-then-copy if destination differs from source.
# Used for runtime files that ship from the repo but may have been customized
# by the user (skills/hooks/scripts/templates). On re-runs of install.sh,
# any local modification is preserved as `<dest>.pre-update.<timestamp>` BEFORE
# being overwritten. Default cp is destructive; this is the safety net.
#
# Behavior:
#   - dest missing             → plain cp (first install)
#   - dest identical to src    → plain cp (no-op, no backup)
#   - dest exists AND differs  → backup dest to <dest>.pre-update.<ts>, then cp
#
# Supports file→file and file→dir destinations (dest resolved via basename if dir).
# For glob sources, call safe_cp in a for-loop — keeps the logic single-file per call.
# Honors --dry-run by printing what would happen without writing anything.
safe_cp() {
  local src="$1" dst="$2"
  # Resolve actual destination path when dst is a directory
  local actual_dst="$dst"
  if [ -d "$dst" ]; then
    actual_dst="${dst%/}/$(basename "$src")"
  fi
  if [ "$DRY_RUN" = true ]; then
    if [ -f "$actual_dst" ] && ! cmp -s "$src" "$actual_dst" 2>/dev/null; then
      printf "${DIM}    would back up modified: %s${NC}\n" "$actual_dst"
    fi
    printf "${DIM}    would run: cp %s %s${NC}\n" "$src" "$dst"
    return 0
  fi
  if [ -f "$actual_dst" ] && ! cmp -s "$src" "$actual_dst" 2>/dev/null; then
    local ts backup
    ts=$(date +%Y%m%d-%H%M%S)
    backup="${actual_dst}.pre-update.${ts}"
    cp "$actual_dst" "$backup"
    warn "Backed up modified $(basename "$actual_dst") → $(basename "$backup")"
    BACKUP_COUNT=$((BACKUP_COUNT + 1))
  fi
  cp "$src" "$dst"
}

# prompt_or_default — read input from tty or fall back to a safe default.
# Usage: var=$(prompt_or_default "<prompt text>" "<default if non-tty or empty>")
# - tty: prints prompt to /dev/tty, reads input from /dev/tty, returns input or default if empty
# - non-tty (CI / cron / piped stdin): silently returns default
#
# /dev/tty is mandatory for both directions: the function is only ever called via
# command substitution `var=$(prompt_or_default ...)` which captures stdout —
# writing the prompt to stdout would route it into the captured value instead of
# the user's terminal, leaving the wizard apparently hung. Reading from /dev/tty
# is defensive symmetry; stdin happens to be the tty in the current call sites,
# but a future caller might pipe stdin without realizing it.
prompt_or_default() {
  local prompt="$1" default="$2" answer
  if [ -t 0 ]; then
    printf "%s" "$prompt" >/dev/tty
    read -r answer </dev/tty
    echo "${answer:-$default}"
  else
    echo "$default"
  fi
}

# set_conf_key — update or append a key=value line in forge.conf in place
set_conf_key() {
  local key="$1" val="$2" conf="$CLAUDE_DIR/forge.conf"
  if grep -q "^${key}=" "$conf" 2>/dev/null; then
    local tmp="${conf}.tmp.$$"
    # Pass via ENVIRON (not -v) so backslash escapes in val are preserved verbatim.
    # awk's -v interprets escape sequences (\n, \t, unknown \X) which would mangle
    # values containing literal backslashes.
    SET_CONF_K="$key" SET_CONF_V="$val" \
      awk 'BEGIN{FS="="; k=ENVIRON["SET_CONF_K"]; v=ENVIRON["SET_CONF_V"]} $1==k {print k"="v; next} {print}' "$conf" > "$tmp" \
      && mv "$tmp" "$conf"
  else
    echo "${key}=${val}" >> "$conf"
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

if ! command -v tmux &>/dev/null; then
  warn "tmux not found — Pattern A agent teams will not work."
  hint "Install: brew install tmux  (macOS)  or  apt install tmux  (Linux)"
  hint "Without tmux, Petra falls back to inline subagent dispatch — same work, no live multi-pane visibility."
else
  TMUX_VERSION=$(tmux -V 2>/dev/null | awk '{print $2}')
  ok "tmux $TMUX_VERSION"
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

# iTerm2 setup — required for clean Pattern A team UX on macOS.
# Idempotent: each setting only writes if not already correct.
if [ "$(uname)" = "Darwin" ] && [ -d "/Applications/iTerm.app" ]; then
  # 1. Enable Python API — required for tmux -CC native pane integration
  CURRENT_API=$(defaults read com.googlecode.iterm2 EnableAPIServer 2>/dev/null || echo "0")
  if [ "$CURRENT_API" != "1" ]; then
    if [ "$DRY_RUN" = true ]; then
      info "Would enable iTerm2 Python API (defaults write com.googlecode.iterm2 EnableAPIServer 1)"
    else
      defaults write com.googlecode.iterm2 EnableAPIServer 1
      ok "iTerm2 Python API enabled (restart iTerm2 to take effect)"
    fi
  else
    ok "iTerm2 Python API already enabled"
  fi

  # 2. Auto-hide tmux gateway client window — buries the "control" window
  # that tmux -CC opens, leaving only the integration window visible.
  # Without this, users see two windows per claude session and find it confusing
  # (the gateway looks frozen on "tmux mode started"). See task
  # 2026-05-07-forge-team-substrate-install (UX iteration after first user trial).
  CURRENT_HIDE=$(defaults read com.googlecode.iterm2 AutoHideTmuxClientSession 2>/dev/null || echo "0")
  if [ "$CURRENT_HIDE" != "1" ]; then
    if [ "$DRY_RUN" = true ]; then
      info "Would auto-hide tmux gateway window (defaults write com.googlecode.iterm2 AutoHideTmuxClientSession -bool true)"
    else
      defaults write com.googlecode.iterm2 AutoHideTmuxClientSession -bool true
      ok "iTerm2 tmux gateway auto-hide enabled (single-window UX for Pattern A teams)"
    fi
  else
    ok "iTerm2 tmux gateway auto-hide already enabled"
  fi
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
  DEFAULT_VAULT="$HOME/Vault"
  if [ "$DRY_RUN" = true ]; then
    VAULT_PATH="$DEFAULT_VAULT"
    info "Would prompt for vault location (default: $VAULT_PATH)"
  else
    custom_path=$(prompt_or_default \
      "$(printf "${CYAN}[forge]${NC} Where should the vault live? [%s]: " "$DEFAULT_VAULT")" \
      "$DEFAULT_VAULT")
    VAULT_PATH="${custom_path/#\~/$HOME}"
  fi
fi

# Expand ~ if present
VAULT_PATH="${VAULT_PATH/#\~/$HOME}"

# Write forge.conf
if [ "$DRY_RUN" = true ]; then
  ok "forge.conf would be written/updated (vault: $VAULT_PATH)"
elif [ -f "$CLAUDE_DIR/forge.conf" ]; then
  # Existing config — only update install-managed keys, preserve user-set values.
  # Other keys (ONBOARDING_COMPLETE, WELLNESS_ENABLED, MODEL_*, VAULT_GIT_DECLINED)
  # are left untouched. Consumer code uses sensible defaults when keys are missing.
  set_conf_key VAULT_PATH "$VAULT_PATH"
  set_conf_key FORGE_REPO "$FORGE_ROOT"
  ok "forge.conf updated (preserved existing user-set values)"
else
  # First install — write full template with defaults.
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

for tpl in "$FORGE_ROOT/core/vault-templates/"*; do safe_cp "$tpl" "$VAULT_PATH/_templates/"; done
ok "Vault structure at $VAULT_PATH"

# ─── Encourage vault git-init ────────────────────────────────────────────────
# Check 1: vault is already a git repo? Skip silently.
# Check 2: user previously declined? Skip silently (flag in forge.conf).
# Check 3: dry-run? Print would-prompt and skip.
# Otherwise: prompt; on Y init+commit scaffold+hint; on N record decline.

if ! git -C "$VAULT_PATH" rev-parse --git-dir &>/dev/null; then
  if grep -q '^VAULT_GIT_DECLINED=true' "$CLAUDE_DIR/forge.conf" 2>/dev/null; then
    : # user previously declined — silent skip
  elif [ "$DRY_RUN" = true ]; then
    info "Would prompt: initialize vault as git repo"
  else
    echo ""
    printf "${CYAN}[forge]${NC} Vault at %s is not under version control.\n" "$VAULT_PATH"
    printf "        Strongly recommended:\n"
    printf "          - Survives laptop loss / disk failure\n"
    printf "          - Enables cross-machine work\n"
    printf "          - Powers vault-state line at session start (drift detection)\n"
    # Non-tty default: 'n' (skip init — too consequential to auto-init silently).
    # Tty empty input: case fallthrough below preserves the historical 'Y' default.
    git_init_answer=$(prompt_or_default \
      "$(printf "        Initialize git in the vault now? [Y/n]: ")" \
      "n")
    case "${git_init_answer:-Y}" in
      [Yy]*|"")
        info "Initializing vault as git repo…"
        run git -C "$VAULT_PATH" init -q
        ok "git init"
        run git -C "$VAULT_PATH" add _shared _templates _meta
        run git -C "$VAULT_PATH" commit -q -m "Initial vault scaffold"
        ok "Initial commit (vault scaffold)"
        hint "Add a remote later: git -C $VAULT_PATH remote add origin <url> && git push -u origin HEAD"
        ;;
      *)
        # Persist decline flag only for interactive declines.
        # Non-tty fallback ('n' default) doesn't represent a real user choice —
        # leave the flag unset so a future interactive install re-prompts.
        if [ "$DRY_RUN" = false ] && [ -t 0 ]; then
          set_conf_key VAULT_GIT_DECLINED true
        fi
        info "Vault left unversioned per user choice."
        ;;
    esac
  fi
fi

# ─── Copy skills ─────────────────────────────────────────────────────────────
ADAPTER="$FORGE_ROOT/adapters/claude-code"
SKILLS_DIR="$CLAUDE_DIR/skills"

echo ""
info "Installing skills..."

# Core skills
for skill in forge forge-checkpoint forge-exit forge-audit-permissions forge-vault-sync keeper refiner plan-reviewer; do
  run mkdir -p "$SKILLS_DIR/$skill"
  safe_cp "$ADAPTER/skills/$skill/SKILL.md" "$SKILLS_DIR/$skill/SKILL.md"
done
ok "Core skills (forge, forge-checkpoint, forge-exit, forge-audit-permissions, forge-vault-sync, keeper, refiner, plan-reviewer)"

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
safe_cp "$WC_SRC/skills/wellness-coach/SKILL.md" "$WC_DST/SKILL.md"
safe_cp "$WC_SRC/README.md" "$WC_DST/"
for hook in "$WC_SRC/hooks/"*.py; do safe_cp "$hook" "$WC_DST/hooks/"; done
for script in "$WC_SRC/scripts/"*; do safe_cp "$script" "$WC_DST/scripts/"; done
safe_cp "$WC_SRC/src/screen_state.c" "$WC_DST/src/"
run chmod +x "$WC_DST/scripts/"*.sh
ok "Wellness coach files (activation offered during first /forge session)"

# ─── Copy agent definitions ──────────────────────────────────────────────────
echo ""
info "Installing agent definitions..."

AGENTS_DIR="$CLAUDE_DIR/agents"
run mkdir -p "$AGENTS_DIR"

for agent in forge-architect forge-debugger forge-impl forge-keeper forge-refiner forge-release forge-reviewer forge-toolsmith; do
  run cp "$ADAPTER/agents/$agent.md" "$AGENTS_DIR/$agent.md"
done
ok "Agent definitions (8 forge-* adapters in ~/.claude/agents/)"

# ─── Copy hooks & scripts ────────────────────────────────────────────────────
echo ""
info "Installing hooks and scripts..."

run mkdir -p "$CLAUDE_DIR/hooks" "$CLAUDE_DIR/scripts"

safe_cp "$ADAPTER/hooks/forge-compaction.sh" "$CLAUDE_DIR/hooks/"
safe_cp "$ADAPTER/hooks/approval-notifier.sh" "$CLAUDE_DIR/hooks/"
safe_cp "$ADAPTER/hooks/forge-vault-plan-guard.sh" "$CLAUDE_DIR/hooks/"
safe_cp "$ADAPTER/hooks/forge-session-end.sh" "$CLAUDE_DIR/hooks/"
safe_cp "$ADAPTER/hooks/inject-current-time.sh" "$CLAUDE_DIR/hooks/"
safe_cp "$ADAPTER/scripts/forge-context.sh" "$CLAUDE_DIR/scripts/"
safe_cp "$ADAPTER/scripts/forge-permission-lint.sh" "$CLAUDE_DIR/scripts/"
safe_cp "$ADAPTER/scripts/statusline.sh" "$CLAUDE_DIR/statusline.sh"

run chmod +x "$CLAUDE_DIR/hooks/forge-compaction.sh" \
             "$CLAUDE_DIR/hooks/approval-notifier.sh" \
             "$CLAUDE_DIR/hooks/forge-vault-plan-guard.sh" \
             "$CLAUDE_DIR/hooks/forge-session-end.sh" \
             "$CLAUDE_DIR/hooks/inject-current-time.sh" \
             "$CLAUDE_DIR/scripts/forge-context.sh" \
             "$CLAUDE_DIR/scripts/forge-permission-lint.sh" \
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
# Bake the safe-permissions baseline so fresh installs don't prompt on every
# Forge action. Source of truth: core/references/forge-permissions.md.
# $HOME and $VAULT_PATH are substituted by shell expansion below.
# Validated by forge-permission-lint (run at end of install) — patterns that
# would silently never match (see check1/check2/check3) fail the install.

# Source forge.conf if present so the wellness conditional below works
WELLNESS_ENABLED="${WELLNESS_ENABLED:-false}"
if [ -f "$CLAUDE_DIR/forge.conf" ]; then
  # shellcheck disable=SC1091
  WELLNESS_ENABLED=$(grep -E '^WELLNESS_ENABLED=' "$CLAUDE_DIR/forge.conf" 2>/dev/null | head -1 | cut -d= -f2 || echo "false")
fi

PERMS_TO_ADD=(
  # Forge scripts
  "Bash($HOME/.claude/scripts/forge-context.sh:*)"
  "Bash($HOME/.claude/scripts/forge-permission-lint.sh:*)"
  "Bash($HOME/.claude/statusline.sh:*)"
  # Forge hooks
  "Bash($HOME/.claude/hooks/forge-compaction.sh:*)"
  "Bash($HOME/.claude/hooks/approval-notifier.sh:*)"
  "Bash($HOME/.claude/hooks/forge-vault-plan-guard.sh:*)"
  # Forge config
  "Read($HOME/.claude/forge.conf)"
  "Edit($HOME/.claude/forge.conf)"
  # Vault (recursive)
  "Read($VAULT_PATH/**)"
  "Write($VAULT_PATH/**)"
  "Edit($VAULT_PATH/**)"
)

# Conditional: wellness coach (only if enabled in forge.conf)
if [ "$WELLNESS_ENABLED" = "true" ]; then
  PERMS_TO_ADD+=(
    "Bash(python3:$HOME/.claude/skills/wellness-coach/hooks/*)"
    "Bash($HOME/.claude/skills/wellness-coach/scripts/*)"
  )
fi

SETTINGS=$(cat "$SETTINGS_FILE")
ADDED_COUNT=0
for perm in "${PERMS_TO_ADD[@]}"; do
  if ! echo "$SETTINGS" | jq -e ".permissions.allow // [] | index(\"$perm\")" &>/dev/null; then
    SETTINGS=$(echo "$SETTINGS" | jq ".permissions.allow = ((.permissions.allow // []) + [\"$perm\"])")
    ADDED_COUNT=$((ADDED_COUNT + 1))
  fi
done
ok "Permissions ($ADDED_COUNT added, $((${#PERMS_TO_ADD[@]} - ADDED_COUNT)) already present)"

# ── Hooks ──
# Helper: add a hook entry if its command doesn't already exist in the event.
# Dedup is tilde-aware: `~/.claude/...` and `$HOME/.claude/...` are treated as
# the same command (shell expands both identically when the hook runs). Without
# this normalization, re-running install.sh after the tilde→$HOME migration
# duplicates every Forge hook entry, causing every hook to fire twice per event.
add_hook() {
  local event="$1" matcher="$2" command="$3" timeout="${4:-5}"
  local settings="$5"

  if echo "$settings" | jq -e --arg cmd "$command" --arg home "$HOME" \
    ".hooks.\"$event\" // [] | .. | .command? // empty
     | (gsub(\$home; \"~\")) as \$stored
     | (\$cmd | gsub(\$home; \"~\")) as \$incoming
     | select(\$stored == \$incoming)" &>/dev/null 2>&1; then
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
SETTINGS=$(add_hook "PreToolUse" "Write|Edit" "$HOME/.claude/hooks/forge-vault-plan-guard.sh" 5 "$SETTINGS")
SETTINGS=$(add_hook "PreCompact" "null" "$HOME/.claude/hooks/forge-compaction.sh pre" 10 "$SETTINGS")
SETTINGS=$(add_hook "PostCompact" "null" "$HOME/.claude/hooks/forge-compaction.sh post" 10 "$SETTINGS")
SETTINGS=$(add_hook "PostToolUse" "null" "$HOME/.claude/scripts/forge-context.sh post-tool" 5 "$SETTINGS")
SETTINGS=$(add_hook "Stop" "null" "$HOME/.claude/scripts/forge-context.sh stop" 5 "$SETTINGS")
SETTINGS=$(add_hook "SessionEnd" "null" "$HOME/.claude/hooks/forge-session-end.sh" 5 "$SETTINGS")
SETTINGS=$(add_hook "UserPromptSubmit" "null" "$HOME/.claude/hooks/inject-current-time.sh" 2 "$SETTINGS")
ok "Hooks (7 core hooks)"

# ── Env vars for agent teams ──
SETTINGS=$(echo "$SETTINGS" | jq '.env = ((.env // {}) + {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"})')
ok "Env: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"

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

# ─── Sanitize inherited leading-* Bash patterns (safety net) ────────────────
# Some upstream installers (notably the Vend Claude wizard) ship `Bash(*foo*)`
# permission patterns. The leading * in Claude Code Bash matchers is interpreted
# literally — these patterns match nothing, but Forge's permission lint will
# fail on them. Surgically remove them so the user ends up with a clean install
# even if they ran another tool first that left broken patterns behind.
#
# Until upstream fixes their installers, Forge acts as the safety net.
if [ "$DRY_RUN" = false ]; then
  BROKEN_COUNT=$(jq '[(.permissions.allow // []) + (.permissions.ask // []) + (.permissions.deny // []) | .[] | select(test("^Bash\\(\\*"))] | length' "$SETTINGS_FILE" 2>/dev/null || echo 0)
  if [ "$BROKEN_COUNT" -gt 0 ]; then
    echo ""
    info "Detected $BROKEN_COUNT inherited \`Bash(*foo*)\` permission pattern(s)..."
    hint "These come from a previous installer (most likely the Vend Claude wizard)."
    hint "Leading * in Bash matchers is literal — these patterns match nothing,"
    hint "and Forge's permission lint will fail on them."
    hint "Backing up + sanitizing so the lint passes."
    SANITIZE_BACKUP="$SETTINGS_FILE.pre-vendor-pattern-sanitize.$(date +%Y%m%d-%H%M%S)"
    cp "$SETTINGS_FILE" "$SANITIZE_BACKUP"
    if jq '
      .permissions.allow //= [] |
      .permissions.ask //= [] |
      .permissions.deny //= [] |
      .permissions.allow |= map(select(test("^Bash\\(\\*") | not)) |
      .permissions.ask   |= map(select(test("^Bash\\(\\*") | not)) |
      .permissions.deny  |= map(select(test("^Bash\\(\\*") | not))
    ' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"; then
      ok "Removed $BROKEN_COUNT broken pattern(s). Backup: $SANITIZE_BACKUP"
      hint "If you need any of those operations to skip approval prompts,"
      hint "ask the source installer to ship them in proper \`prefix*\` form."
    else
      rm -f "$SETTINGS_FILE.tmp"
      warn "Sanitization failed (jq error) — settings.json left as-is."
      hint "Backup at $SANITIZE_BACKUP. The lint step will surface the bad patterns."
    fi
  fi
fi

# ─── Install shell wrapper for Pattern A team substrate ──────────────────────
echo ""
info "Installing shell wrapper for agent teams..."

WRAPPER_FILE="$CLAUDE_DIR/forge-shell-init.sh"
WRAPPER_SOURCE="$ADAPTER/scripts/forge-shell-init.sh"

safe_cp "$WRAPPER_SOURCE" "$WRAPPER_FILE"
ok "Wrapper installed at $WRAPPER_FILE"

# tmux config consumed by the wrapper — sources user's ~/.tmux.conf then forces
# `mouse on` so wheel events scroll tmux's own buffer instead of being translated
# to arrow keys by the alt-screen (which Claude Code receives as junk input).
TMUX_CONF_FILE="$CLAUDE_DIR/forge-tmux.conf"
TMUX_CONF_SOURCE="$ADAPTER/scripts/forge-tmux.conf"

safe_cp "$TMUX_CONF_SOURCE" "$TMUX_CONF_FILE"
ok "tmux config installed at $TMUX_CONF_FILE"

# Detect user's shell rc file
SHELL_RC=""
case "${SHELL##*/}" in
  zsh) SHELL_RC="$HOME/.zshrc" ;;
  bash) SHELL_RC="$HOME/.bashrc" ;;
  fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
esac

if [ -z "$SHELL_RC" ]; then
  warn "Couldn't detect your shell rc file (\$SHELL=$SHELL)."
  hint "Manually source ~/.claude/forge-shell-init.sh in your shell init."
elif [ ! -f "$SHELL_RC" ]; then
  warn "$SHELL_RC not found."
  hint "Create it and add: [ -f ~/.claude/forge-shell-init.sh ] && source ~/.claude/forge-shell-init.sh"
elif grep -q "forge-shell-init.sh" "$SHELL_RC"; then
  ok "Wrapper already sourced in $SHELL_RC"
elif [ "$SHELL_RC" = "$HOME/.config/fish/config.fish" ]; then
  warn "Fish shell detected — wrapper uses bash/zsh syntax, not fish-compatible."
  hint "Fish port not yet shipped. File an issue if you'd like one."
  hint "Manual port reference: $WRAPPER_FILE"
else
  if grep -q "^[[:space:]]*alias[[:space:]]\+claude=" "$SHELL_RC" || \
     grep -q "^[[:space:]]*claude[[:space:]]*()" "$SHELL_RC"; then
    warn "$SHELL_RC already defines 'claude' (alias or function) — wrapper may conflict."
    hint "Review existing definition before sourcing the wrapper."
  fi
  WRAPPER_OPT_IN=$(prompt_or_default \
    "$(printf "${CYAN}[forge]${NC} Append shell wrapper source line to %s? [Y/n]: " "$SHELL_RC")" \
    "Y")
  case "${WRAPPER_OPT_IN:-Y}" in
    [Yy]*|"")
      if [ "$DRY_RUN" = true ]; then
        info "Would append source line to $SHELL_RC"
      else
        cat >> "$SHELL_RC" <<EOF

# Forge shell wrapper — auto-tmux for Pattern A agent teams (added by forge install.sh)
[ -f ~/.claude/forge-shell-init.sh ] && source ~/.claude/forge-shell-init.sh
EOF
        ok "Wrapper sourced in $SHELL_RC"
        hint "Open a new terminal (or 'source $SHELL_RC') for the wrapper to take effect."
      fi
      ;;
    *)
      warn "Skipped — wrapper not sourced. Pattern A team substrate disabled."
      hint "To enable later, add this line to $SHELL_RC manually:"
      hint "  [ -f ~/.claude/forge-shell-init.sh ] && source ~/.claude/forge-shell-init.sh"
      ;;
  esac
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

# ─── Validate settings.json against known anti-patterns ─────────────────────
echo ""
info "Validating settings.json for known anti-patterns..."

if [ "$DRY_RUN" = true ]; then
  ok "Skipped (dry run)"
elif "$CLAUDE_DIR/scripts/forge-permission-lint.sh"; then
  ok "settings.json validation passed"
else
  echo ""
  echo "  ✗ settings.json validation failed — see findings above."
  echo "    Fix the patterns and re-run install.sh."
  echo "    (If the bad patterns came from install.sh itself, file a forge bug.)"
  exit 1
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
echo "  Core skills:   forge, forge-checkpoint, forge-exit, forge-audit-permissions,"
echo "                 keeper, refiner, plan-reviewer"
echo "  Agents:        forge-architect, forge-debugger, forge-impl, forge-keeper,"
echo "                 forge-refiner, forge-release, forge-reviewer, forge-toolsmith"
echo "  Wellness:      files ready — offered during onboarding"
echo "  Vault:         $VAULT_PATH"
echo "  Config:        ~/.claude/forge.conf"
echo "  Backup:        ~/.claude/settings.json.forge-backup"
if [ "$BACKUP_COUNT" -gt 0 ]; then
  echo "  Pre-update:    $BACKUP_COUNT user-modified file(s) backed up as <file>.pre-update.<timestamp>"
  echo "                 (re-run-safe: customizations preserved, not lost)"
fi
echo ""
echo "  Team substrate (Pattern A agent teams):"
if command -v tmux &>/dev/null; then
  printf "    tmux:        %s\n" "$(tmux -V 2>/dev/null | awk '{print $2}')"
else
  printf "    tmux:        ${YELLOW}not installed${NC} — Pattern A teams unavailable\n"
fi
if [ "$(uname)" = "Darwin" ] && [ -d "/Applications/iTerm.app" ]; then
  echo "    iTerm2 API:  enabled"
fi
echo "    Wrapper:     ~/.claude/forge-shell-init.sh"
hint "Open a fresh terminal — your 'claude' command now auto-wraps in tmux"
hint "for Pattern A team support. Scripts using 'claude -p' are unaffected."
echo ""
echo "  Next step:     type /forge in Claude Code to start"
echo ""
echo "  Dependencies:"
echo "    Required:    superpowers"
hint "https://github.com/obra/superpowers-marketplace"
echo "    Recommended: code-review, commit-commands, pr-review-toolkit"
hint "Available from claude-plugins-official marketplace"
echo ""
