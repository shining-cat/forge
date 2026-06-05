#!/bin/bash
# Forge Installer — copies Forge components into ~/.claude/ and wires hooks/permissions
#
# Usage: ./install.sh [--vault-path PATH] [--dry-run] [--preview] [--interactive]
#
# Options:
#   --vault-path PATH  Set vault location (default: ~/Vault)
#   --dry-run          Show what would be done without changing anything
#   --preview          Read-only summary of pending changes (new/modified/removed files
#                      + settings.json additions). Exit 0 = in sync, 1 = drift, 2 = error.
#                      No prompts, no writes — safe to run from drift-detection hooks.
#   --interactive      Run --preview first; if changes pending, prompt Y/n; on Y, apply.
#                      On N (or empty/non-tty), exit without applying.
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
PREVIEW=false
INTERACTIVE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --vault-path) VAULT_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --preview) PREVIEW=true; shift ;;
    --interactive) INTERACTIVE=true; shift ;;
    -h|--help)
      sed -n '2,/^$/s/^# //p' "$0"
      exit 0
      ;;
    *) fail "Unknown option: $1" ;;
  esac
done

# --preview and --interactive are mutually exclusive: --preview is read-only-then-exit,
# --interactive is read-only-then-prompt-then-apply. Mixing them is ambiguous.
if [ "$PREVIEW" = true ] && [ "$INTERACTIVE" = true ]; then
  fail "--preview and --interactive are mutually exclusive."
fi

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

# safe_cp — backup-then-copy with optional preserve policy.
# Used for runtime files that ship from the repo but may have been customized
# by the user (skills/hooks/scripts/templates). On re-runs of install.sh, the
# default "overwrite" policy preserves any local modification as
# `<dest>.pre-update.<timestamp>` BEFORE writing upstream. The "preserve" policy
# (Slice 3, A2 bucket) leaves modified destinations untouched and instead writes
# `<dest>.upstream.<ts>` so the user can diff at leisure.
#
# Args: $1=src $2=dst [$3=policy: overwrite|preserve; default overwrite]
#
# overwrite behavior:
#   - dest missing             → plain cp (first install)
#   - dest identical to src    → plain cp (no-op, no backup)
#   - dest exists AND differs  → backup dest to <dest>.pre-update.<ts>, then cp
#
# preserve behavior (Apache-config style):
#   - dest missing             → plain cp (first install, no sibling)
#   - dest identical to src    → no-op
#   - dest exists AND differs  → write_upstream_sibling (leaves dest untouched)
#
# Supports file→file and file→dir destinations (dest resolved via basename if dir).
# For glob sources, call safe_cp in a for-loop — keeps the logic single-file per call.
# Honors --dry-run by printing what would happen without writing anything.
safe_cp() {
  local src="$1" dst="$2" policy="${3:-overwrite}"
  # Resolve actual destination path when dst is a directory
  local actual_dst="$dst"
  if [ -d "$dst" ]; then
    actual_dst="${dst%/}/$(basename "$src")"
  fi

  if [ "$policy" = "preserve" ]; then
    if [ ! -e "$actual_dst" ] && [ ! -L "$actual_dst" ]; then
      if [ "$DRY_RUN" = true ]; then
        printf "${DIM}    would run: cp %s %s${NC}\n" "$src" "$actual_dst"
      else
        cp "$src" "$actual_dst"
      fi
      return 0
    fi
    if [ -f "$actual_dst" ] && cmp -s "$src" "$actual_dst" 2>/dev/null; then
      # Local now matches upstream — any historical .upstream.<ts> siblings
      # are stale comparisons, prune them all.
      prune_old_upstream_siblings "$actual_dst" none
      return 0  # already matches, no-op
    fi
    write_upstream_sibling "$src" "$actual_dst" "file"
    return 0
  fi

  # overwrite (default — Slice 2 behavior)
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

# prune_old_upstream_siblings — bound clutter from accumulated installs.
#
# Each preserve cycle can leave a `<dst>.upstream.<ts>` sibling. Re-runs
# of install.sh against the same diverged local file would stack up N
# siblings over N installs — only the most recent comparison is useful;
# older ones are noise the user has to ignore.
#
# Policy:
#   keep=latest (default) — delete all but the most recent sibling. Used
#                           when we just wrote a new sibling OR when an
#                           existing sibling already matches src.
#   keep=none             — delete all siblings. Used when local now
#                           matches upstream (no preserve needed, all
#                           historical comparisons stale).
#
# Args: $1=dst  $2=keep-policy ("latest"|"none", default "latest")
#
# Side effects: bumps PRUNED_SIBLING_COUNT for each removal. Honors
# --dry-run (prints what would be removed without touching the FS).
PRUNED_SIBLING_COUNT=0
prune_old_upstream_siblings() {
  local dst="$1" keep="${2:-latest}"
  local dir base
  dir="$(dirname "$dst")"
  base="$(basename "$dst")"
  [ -d "$dir" ] || return 0

  local siblings=() f
  # ls -1 + sort: filenames end in `.upstream.YYYYMMDD-HHMMSS`; lex-sort
  # equals chronological. `|| true` defends against set -euo pipefail when
  # the glob has no matches (ls exits 2, pipefail propagates).
  while IFS= read -r f; do
    [ -n "$f" ] && siblings+=("$f")
  done < <(ls -1 "$dir/$base".upstream.* 2>/dev/null | sort || true)

  local count="${#siblings[@]}"
  [ "$count" -eq 0 ] && return 0

  local last_idx=$(( count - 1 )) i
  for i in "${!siblings[@]}"; do
    # keep=latest: skip the last (newest) entry
    if [ "$keep" = "latest" ] && [ "$i" -eq "$last_idx" ]; then
      continue
    fi
    if [ "$DRY_RUN" = true ]; then
      printf "${DIM}    would prune stale sibling: %s${NC}\n" "${siblings[$i]}"
    else
      rm -f "${siblings[$i]}"
    fi
    PRUNED_SIBLING_COUNT=$((PRUNED_SIBLING_COUNT + 1))
  done
}

# write_upstream_sibling — write a `.upstream.<ts>` sibling beside `dst`
# capturing what install.sh would have installed (src content for files,
# link target for symlinks). The "preserve" branch of safe_cp /
# install_symlink calls this when local has been tuned away from upstream
# and we don't want to overwrite it.
#
# Args: $1=src $2=dst $3=type ("file"|"skill_md"|"symlink")
#
# Clutter control (Slice 3 plan Q1 (b)): if the most recent existing
# sibling already matches `src`, skip — a user who hasn't touched their
# statusline shouldn't accumulate N siblings from N install re-runs that
# didn't change upstream. Stale-sibling pruning (this PR): both the
# skip-because-matched and the just-wrote-new paths prune older siblings,
# leaving at most one per file. Safe_cp / install_symlink's "local now
# matches upstream" no-op branches prune ALL siblings (none useful).
#
# Side effects: writes sibling, bumps BACKUP_COUNT, emits a warn line,
# prunes older siblings. Honors --dry-run.
write_upstream_sibling() {
  local src="$1" dst="$2" type="$3"
  local dir base latest_sibling
  dir="$(dirname "$dst")"
  base="$(basename "$dst")"

  # Q1(b) — latest sibling lex-sort == chronological (ts format guarantees it).
  # `|| true` defends against `set -euo pipefail`: ls with no matches exits
  # non-zero and pipefail propagates that to the pipeline. We want an empty
  # string when nothing exists, not an aborted function.
  latest_sibling=""
  if [ -d "$dir" ]; then
    # shellcheck disable=SC2012  # ls is fine here; sibling names contain only safe chars
    latest_sibling=$(ls -1 "$dir/$base".upstream.* 2>/dev/null | sort | tail -1 || true)
  fi

  local should_skip=false
  if [ -n "$latest_sibling" ] && { [ -e "$latest_sibling" ] || [ -L "$latest_sibling" ]; }; then
    case "$type" in
      file)
        cmp -s "$src" "$latest_sibling" 2>/dev/null && should_skip=true
        ;;
      skill_md)
        local sub_tmp
        sub_tmp=$(mktemp)
        if grep -q '{{VAULT}}' "$src" 2>/dev/null; then
          sed "s|{{VAULT}}|${VAULT_PATH}|g" "$src" > "$sub_tmp"
        else
          cp "$src" "$sub_tmp"
        fi
        cmp -s "$sub_tmp" "$latest_sibling" 2>/dev/null && should_skip=true
        rm -f "$sub_tmp"
        ;;
      symlink)
        if [ -L "$latest_sibling" ] && [ "$(readlink "$latest_sibling")" = "$src" ]; then
          should_skip=true
        fi
        ;;
    esac
  fi

  if [ "$should_skip" = true ]; then
    # Latest sibling matches upstream — no new write needed, but prune any
    # older stale siblings so we keep at most the one that's load-bearing.
    prune_old_upstream_siblings "$dst" latest
    return 0
  fi

  local ts sibling
  ts=$(date +%Y%m%d-%H%M%S)
  sibling="${dst}.upstream.${ts}"

  if [ "$DRY_RUN" = true ]; then
    printf "${DIM}    would preserve %s; upstream sibling: %s${NC}\n" "$dst" "$sibling"
    return 0
  fi

  case "$type" in
    file)
      cp "$src" "$sibling"
      ;;
    skill_md)
      if grep -q '{{VAULT}}' "$src" 2>/dev/null; then
        sed "s|{{VAULT}}|${VAULT_PATH}|g" "$src" > "$sibling"
      else
        cp "$src" "$sibling"
      fi
      ;;
    symlink)
      ln -s "$src" "$sibling"
      ;;
  esac
  warn "Preserved local $(basename "$dst") — upstream at $(basename "$sibling")"
  BACKUP_COUNT=$((BACKUP_COUNT + 1))
  # New sibling written — drop any older `.upstream.*` cousins, they're
  # superseded by this one.
  prune_old_upstream_siblings "$dst" latest
}

# install_symlink — install or preserve a symlink with policy support.
# Args: $1=src (link target) $2=dst (link path) [$3=policy: overwrite|preserve; default overwrite]
#
# overwrite policy (default): rm -f + ln -s (legacy Slice 2 behavior).
# preserve policy (Slice 3 A2):
#   - dst missing                                  → ln -s (no sibling)
#   - dst is symlink AND readlink(dst) == src      → no-op
#   - dst is symlink with different target, OR dst is a regular file (user
#     copy-converted to edit locally)              → write_upstream_sibling,
#                                                    leave dst untouched.
install_symlink() {
  local src="$1" dst="$2" policy="${3:-overwrite}"

  if [ "$policy" = "preserve" ]; then
    if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
      if [ "$DRY_RUN" = true ]; then
        printf "${DIM}    would run: ln -s %s %s${NC}\n" "$src" "$dst"
      else
        ln -s "$src" "$dst"
      fi
      return 0
    fi
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
      # Symlink now points where upstream wants — historical .upstream.<ts>
      # siblings are stale, prune them all.
      prune_old_upstream_siblings "$dst" none
      return 0  # already correct
    fi
    write_upstream_sibling "$src" "$dst" "symlink"
    return 0
  fi

  # overwrite (default)
  if [ "$DRY_RUN" = true ]; then
    printf "${DIM}    would run: rm -f %s && ln -s %s %s${NC}\n" "$dst" "$src" "$dst"
    return 0
  fi
  rm -f "$dst"
  ln -s "$src" "$dst"
}

# prompt_or_default — read input from tty or fall back to a safe default.
# Usage: var=$(prompt_or_default "<prompt text>" "<tty-empty default>" ["<non-tty default>"])
# - tty + user input: returns input
# - tty + empty input (Enter): returns 2nd arg ("tty-empty default")
# - non-tty (CI / cron / piped stdin): returns 3rd arg if given, otherwise 2nd arg
#
# The split matters when the display says `[Y/n]:` (Enter accepts Y by convention)
# but the safe non-interactive behavior is different — e.g. "init the vault now?"
# wants tty-empty=Y to match the display, but non-tty=n to avoid auto-initializing
# a vault under a CI job that pressed Enter implicitly. Single-default callers
# (2 args) keep the legacy behavior unchanged.
#
# /dev/tty is mandatory for both directions: the function is only ever called via
# command substitution `var=$(prompt_or_default ...)` which captures stdout —
# writing the prompt to stdout would route it into the captured value instead of
# the user's terminal, leaving the wizard apparently hung. Reading from /dev/tty
# is defensive symmetry; stdin happens to be the tty in the current call sites,
# but a future caller might pipe stdin without realizing it.
prompt_or_default() {
  local prompt="$1" default="$2" non_tty_default="${3:-$2}" answer
  if [ -t 0 ]; then
    printf "%s" "$prompt" >/dev/tty
    read -r answer </dev/tty
    echo "${answer:-$default}"
  else
    echo "$non_tty_default"
  fi
}

# install_skill_md — install a SKILL.md, substituting {{VAULT}} → $VAULT_PATH,
# with safe_cp-style backup of locally-modified destinations.
#
# Skills that reference the vault from runtime guidance (keeper, refiner,
# forge-checkpoint) embed {{VAULT}} placeholders so the source file stays
# portable. The expected on-disk content is therefore the substituted form,
# not the raw source — naive `cmp src dst` would always report a difference
# for placeholder skills and trigger spurious backups every install.
#
# Behavior mirrors safe_cp:
#   - dst missing                       → install (no backup)
#   - dst identical to expected content → install (no-op, no backup)
#   - dst exists AND differs            → backup dst to <dst>.pre-update.<ts>, then install
install_skill_md() {
  local src="$1" dst="$2"
  local has_placeholder=false
  if grep -q '{{VAULT}}' "$src" 2>/dev/null; then
    has_placeholder=true
  fi

  if [ "$DRY_RUN" = true ]; then
    if [ "$has_placeholder" = true ]; then
      printf "${DIM}    would install: %s → %s (with {{VAULT}} → %s)${NC}\n" "$src" "$dst" "$VAULT_PATH"
    else
      printf "${DIM}    would install: %s → %s${NC}\n" "$src" "$dst"
    fi
    return
  fi

  # Build the expected install content so we can compare it against the
  # current destination — this is what backup decisions hinge on.
  local expected
  expected="$(mktemp)"
  if [ "$has_placeholder" = true ]; then
    sed "s|{{VAULT}}|${VAULT_PATH}|g" "$src" > "$expected"
  else
    cp "$src" "$expected"
  fi

  if [ -f "$dst" ] && ! cmp -s "$expected" "$dst" 2>/dev/null; then
    local ts backup
    ts=$(date +%Y%m%d-%H%M%S)
    backup="${dst}.pre-update.${ts}"
    cp "$dst" "$backup"
    warn "Backed up modified $(basename "$dst") → $(basename "$backup")"
    BACKUP_COUNT=$((BACKUP_COUNT + 1))
  fi

  cp "$expected" "$dst"
  rm -f "$expected"
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

# build_pairs — single source of truth for "what install.sh ships".
# Emits TAB-separated 4-tuples: <src>\t<dst>\t<type>\t<policy>, sorted by dst.
#
# Types:
#   file      — plain copy (safe_cp / cp)
#   skill_md  — SKILL.md going through install_skill_md ({{VAULT}}-aware)
#   symlink   — `ln -s <src> <dst>` (src is the symlink TARGET, not a content file)
#
# Policies (Slice 3):
#   overwrite — Slice-2 behavior: back up local mods to .pre-update.<ts> then
#               install upstream. Use for everything install.sh fully owns
#               (code, machinery, persona-bearing prose, agent definitions).
#   preserve  — Apache-config-style: if dst is missing → install. If dst matches
#               src → skip. If dst differs from src → leave dst untouched and
#               write <dst>.upstream.<ts> sibling so the user can diff. Use for
#               files designed to be tuned locally (statusline.sh, forge-tmux.conf,
#               reference symlinks). See "preserve-always (A2)" in the Slice 3
#               plan (`Vault/PERSO/forge/tasks/open/2026-04-24-forge-install-sync-with-source.md`).
#
# Resolves at call time; depends on $CLAUDE_DIR, $SKILLS_DIR, $AGENTS_DIR,
# $ADAPTER, $FORGE_ROOT being set before invocation.
#
# Scope: only files install.sh ships as 1:1 copies/symlinks from FORGE_ROOT.
# Excluded by design (same as the old build_manifest contract):
#   - $CLAUDE_DIR/forge.conf       (user-mutable; removal would be catastrophic)
#   - $CLAUDE_DIR/settings.json    (merged into, not owned)
#   - shell rc edits               (line-level mutation, not file ownership)
#   - vault contents               (lives outside ~/.claude/)
build_pairs() {
  {
    # Core skills (SKILL.md per skill dir) — install_skill_md handles {{VAULT}}
    for skill in forge forge-checkpoint forge-exit forge-weekly forge-audit forge-audit-permissions forge-vault-sync keeper refiner plan-reviewer; do
      printf "%s\t%s\tskill_md\toverwrite\n" "$ADAPTER/skills/$skill/SKILL.md" "$SKILLS_DIR/$skill/SKILL.md"
    done

    # Forge skill references (symlinks to core/references/*) — A2: preserve local edits
    for ref in lifecycle.md vocabulary.md wellness-awareness.md script-replacement-patterns.md friction-classifier.md onboarding.md agent-teams-mode.md wellness-cold-start.md prose-wind-down.md wrap-up-state.md; do
      printf "%s\t%s\tsymlink\tpreserve\n" "$FORGE_ROOT/core/references/$ref" "$SKILLS_DIR/forge/references/$ref"
    done

    # Quartermaster reference (scoped symlink under forge-weekly skill) — A2
    printf "%s\t%s\tsymlink\tpreserve\n" "$FORGE_ROOT/core/references/quartermaster.md" "$SKILLS_DIR/forge-weekly/references/quartermaster.md"

    # Wellness coach (skill + hooks + scripts + src + references)
    local wc_dst="$SKILLS_DIR/wellness-coach"
    local wc_src="$ADAPTER/modules/wellness-coach"
    printf "%s\t%s\tfile\toverwrite\n" "$wc_src/skills/wellness-coach/SKILL.md" "$wc_dst/SKILL.md"
    printf "%s\t%s\tfile\toverwrite\n" "$wc_src/README.md" "$wc_dst/README.md"
    for hook in "$wc_src/hooks/"*.py; do
      [ -e "$hook" ] && printf "%s\t%s\tfile\toverwrite\n" "$hook" "$wc_dst/hooks/$(basename "$hook")"
    done
    for script in "$wc_src/scripts/"*; do
      # Skip subdirs (e.g. tests/) — only top-level script files get installed
      [ -f "$script" ] && printf "%s\t%s\tfile\toverwrite\n" "$script" "$wc_dst/scripts/$(basename "$script")"
    done
    printf "%s\t%s\tfile\toverwrite\n" "$wc_src/src/screen_state.c" "$wc_dst/src/screen_state.c"
    # Wellness-coach references — A2 (same logic as forge skill references)
    for ref in onboarding.md conflict-resolution.md window-isolation.md personas.md auto-detected-tiers.md strike-conversation.md; do
      printf "%s\t%s\tsymlink\tpreserve\n" "$wc_src/references/$ref" "$wc_dst/references/$ref"
    done

    # Agent definitions (forge-* adapter files)
    for agent in forge-architect forge-debugger forge-impl forge-keeper forge-refiner forge-release forge-reviewer forge-toolsmith; do
      printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/agents/$agent.md" "$AGENTS_DIR/$agent.md"
    done

    # Hooks (5)
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/hooks/forge-compaction.sh"          "$CLAUDE_DIR/hooks/forge-compaction.sh"
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/hooks/approval-notifier.sh"         "$CLAUDE_DIR/hooks/approval-notifier.sh"
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/hooks/forge-vault-plan-guard.sh"    "$CLAUDE_DIR/hooks/forge-vault-plan-guard.sh"
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/hooks/forge-session-end.sh"         "$CLAUDE_DIR/hooks/forge-session-end.sh"
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/hooks/inject-current-time.sh"       "$CLAUDE_DIR/hooks/inject-current-time.sh"

    # Scripts (6)
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/scripts/forge-context.sh"               "$CLAUDE_DIR/scripts/forge-context.sh"
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/scripts/forge-permission-lint.sh"       "$CLAUDE_DIR/scripts/forge-permission-lint.sh"
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/scripts/forge-classify-friction.sh"     "$CLAUDE_DIR/scripts/forge-classify-friction.sh"
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/scripts/forge-gap-since-last-signal.sh" "$CLAUDE_DIR/scripts/forge-gap-since-last-signal.sh"
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/scripts/forge-calendar.sh"              "$CLAUDE_DIR/scripts/forge-calendar.sh"
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/scripts/forge-cost-snapshot.sh"         "$CLAUDE_DIR/scripts/forge-cost-snapshot.sh"

    # Top-level files under ~/.claude/
    # statusline.sh + forge-tmux.conf are A2 (preserve) — power users tune them.
    # forge-shell-init.sh is C (overwrite) — bootstrap script, not a tunable config.
    printf "%s\t%s\tfile\tpreserve\n" "$ADAPTER/scripts/statusline.sh"        "$CLAUDE_DIR/statusline.sh"
    printf "%s\t%s\tfile\toverwrite\n" "$ADAPTER/scripts/forge-shell-init.sh" "$CLAUDE_DIR/forge-shell-init.sh"
    printf "%s\t%s\tfile\tpreserve\n" "$ADAPTER/scripts/forge-tmux.conf"      "$CLAUDE_DIR/forge-tmux.conf"
  } | sort -t$'\t' -k2,2
}

# build_manifest — destination paths only, one per line, sorted.
# Compatibility shim around build_pairs. Read by `--preview` on subsequent runs
# to compute removals (paths in old manifest absent from current build_pairs).
build_manifest() {
  build_pairs | cut -f2
}

# validate_preserved_a2_files — warn if any A2-preserve file is syntactically broken.
#
# A2-preserve (Slice 3, PR #42) intentionally keeps locally-modified versions of
# power-user-tunable files (statusline.sh, forge-tmux.conf, reference symlinks)
# across install runs. The policy correctly preserves files but has no way to
# know if the local modifications are *valid* — bash syntax errors, invalid
# JSON, etc., all get preserved equally.
#
# 2026-05-28 ~> 2026-06-01: `~/.claude/statusline.sh` had `fi#` (missing space
# between `fi` and a trailing comment) from unflushed Slice 3 smoke-test
# mutations. A2-preserve faithfully preserved the broken file on every install;
# Claude Code's statusline-script failure is silent → 4 days of statusline
# blackout that no one noticed until the user reported it by eye.
#
# This pass catches the recurrence pattern: walk A2-preserve files, run a cheap
# syntax check based on extension (.sh → bash -n, .json → jq empty), warn on
# failures. Warnings only — does NOT fail the install (local state belongs to
# the user; install just surfaces problems so they can fix them).
#
# Extensions without a cheap syntax check (.md, .conf, symlinks, etc.) are
# skipped silently. Adding new checks: extend the case below.
validate_preserved_a2_files() {
  local pairs_output broken=()
  pairs_output="$(build_pairs 2>/dev/null)" || return 0

  while IFS=$'\t' read -r src dst type policy; do
    [ "$policy" = "preserve" ] || continue
    [ "$type" = "file" ] || continue
    [ -f "$dst" ] || continue

    case "$dst" in
      *.sh)
        bash -n "$dst" 2>/dev/null || broken+=("$dst|bash syntax error (try: bash -n $dst)")
        ;;
      *.json)
        if command -v jq >/dev/null 2>&1; then
          jq empty "$dst" >/dev/null 2>&1 || broken+=("$dst|invalid JSON (try: jq empty $dst)")
        fi
        ;;
      # .md, .conf, others — no cheap syntax check, skip silently.
    esac
  done <<< "$pairs_output"

  if [ "${#broken[@]}" -gt 0 ]; then
    echo ""
    warn "A2-preserve file(s) appear broken — install kept them as-is per policy."
    hint "These are files where install preserves your local edits (statusline.sh, etc.)."
    hint "Diff against the .upstream.<timestamp> sibling and restore the parts you need."
    local entry path reason
    for entry in "${broken[@]}"; do
      path="${entry%%|*}"
      reason="${entry#*|}"
      printf "    %s  ${YELLOW}(%s)${NC}\n" "$path" "$reason"
    done
  fi
}

# files_equal — return 0 if dst matches what install.sh would write for src+type.
# Returns 1 on missing dst or content/target mismatch.
#
# Match rules:
#   file      — cmp -s src dst
#   skill_md  — substitute {{VAULT}} → $VAULT_PATH (absolute, same as install_skill_md)
#               then cmp the substituted form against dst
#   symlink   — dst must be a symlink AND readlink == src
files_equal() {
  local src="$1" dst="$2" type="$3"
  case "$type" in
    file)
      [ -f "$dst" ] || return 1
      cmp -s "$src" "$dst" 2>/dev/null
      ;;
    skill_md)
      [ -f "$dst" ] || return 1
      if grep -q '{{VAULT}}' "$src" 2>/dev/null; then
        local tmp rc
        tmp=$(mktemp)
        sed "s|{{VAULT}}|${VAULT_PATH}|g" "$src" > "$tmp"
        cmp -s "$tmp" "$dst" 2>/dev/null; rc=$?
        rm -f "$tmp"
        return $rc
      else
        cmp -s "$src" "$dst" 2>/dev/null
      fi
      ;;
    symlink)
      [ -L "$dst" ] || return 1
      [ "$(readlink "$dst")" = "$src" ]
      ;;
    *)
      return 1
      ;;
  esac
}

# resolve_install_state — populate VAULT_PATH / WELLNESS_ENABLED /
# PERMISSIVE_BASH_WRAPPERS from forge.conf without prompting or writing.
# Used by the --preview / --interactive short-circuit before the full apply
# flow's vault-prompt + forge.conf-write steps.
#
# Resolution order for VAULT_PATH:
#   1. Already set (e.g. by --vault-path arg) — keep it
#   2. forge.conf VAULT_PATH= entry
#   3. Default: $HOME/Vault
resolve_install_state() {
  local conf="$CLAUDE_DIR/forge.conf"
  if [ -z "$VAULT_PATH" ] && [ -f "$conf" ]; then
    VAULT_PATH=$(grep '^VAULT_PATH=' "$conf" 2>/dev/null | head -1 | cut -d= -f2- || true)
  fi
  [ -z "$VAULT_PATH" ] && VAULT_PATH="$HOME/Vault"
  VAULT_PATH="${VAULT_PATH/#\~/$HOME}"

  WELLNESS_ENABLED=false
  if [ -f "$conf" ] && grep -qE '^WELLNESS_ENABLED=true' "$conf" 2>/dev/null; then
    WELLNESS_ENABLED=true
  fi
  PERMISSIVE_BASH_WRAPPERS=false
  if [ -f "$conf" ] && grep -qE '^PERMISSIVE_BASH_WRAPPERS=true' "$conf" 2>/dev/null; then
    PERMISSIVE_BASH_WRAPPERS=true
  fi
}

# expected_perms — emit the permission strings install.sh would add, one per
# line. Mirrors the PERMS_TO_ADD block further down. Single source of truth
# means preview and apply can't drift.
expected_perms() {
  local perms=(
    "Bash($HOME/.claude/scripts/forge-context.sh:*)"
    "Bash($HOME/.claude/scripts/forge-permission-lint.sh:*)"
    "Bash($HOME/.claude/scripts/forge-classify-friction.sh:*)"
    "Bash($HOME/.claude/scripts/forge-gap-since-last-signal.sh:*)"
    "Bash($HOME/.claude/scripts/forge-calendar.sh:*)"
    "Bash($HOME/.claude/scripts/forge-calendar.sh *)"
    "Bash(~/.claude/scripts/forge-calendar.sh *)"
    "Bash($HOME/.claude/scripts/forge-cost-snapshot.sh:*)"
    "Bash($HOME/.claude/statusline.sh:*)"
    "Bash($HOME/.claude/hooks/forge-compaction.sh:*)"
    "Bash($HOME/.claude/hooks/approval-notifier.sh:*)"
    "Bash($HOME/.claude/hooks/forge-vault-plan-guard.sh:*)"
    "Bash($HOME/.claude/hooks/forge-session-end.sh:*)"
    "Bash($HOME/.claude/hooks/inject-current-time.sh:*)"
    "Read($HOME/.claude/forge.conf)"
    "Edit($HOME/.claude/forge.conf)"
    "Read($VAULT_PATH/**)"
    "Write($VAULT_PATH/**)"
    "Edit($VAULT_PATH/**)"
  )
  if [ "$WELLNESS_ENABLED" = "true" ]; then
    perms+=(
      "Bash(python3:$HOME/.claude/skills/wellness-coach/hooks/*)"
      "Bash($HOME/.claude/skills/wellness-coach/scripts/*)"
    )
  fi
  # Maintainer-only: when working on the forge repo source-of-truth, Petra
  # routinely invokes scripts at $FORGE_ROOT/adapters/... rather than the
  # deployed $HOME/.claude/ copies. Allowlist the source paths under
  # MAINTAINER_MODE=true so dev work doesn't hit per-call prompts. End users
  # don't have the forge repo at these paths; the patterns never match anything
  # for them, but appear in their settings.json — gating on MAINTAINER_MODE
  # keeps end-user settings.json clean. Reads MAINTAINER_MODE from forge.conf
  # at preview time so the displayed list matches what will be applied.
  local maint_mode="false"
  if [ -f "$CLAUDE_DIR/forge.conf" ]; then
    maint_mode="$(grep '^MAINTAINER_MODE=' "$CLAUDE_DIR/forge.conf" 2>/dev/null | head -1 | cut -d= -f2 || true)"
    [ -z "$maint_mode" ] && maint_mode="false"
  fi
  if [ "$maint_mode" = "true" ]; then
    perms+=(
      "Bash($FORGE_ROOT/adapters/claude-code/scripts/*)"
      "Bash($FORGE_ROOT/adapters/claude-code/hooks/*)"
      "Bash($FORGE_ROOT/adapters/claude-code/modules/wellness-coach/scripts/*)"
      "Bash(python3:$FORGE_ROOT/adapters/claude-code/modules/wellness-coach/hooks/*)"
      "Bash($FORGE_ROOT/scripts/lint/no-hardcoded-paths.sh:*)"
      "Bash($FORGE_ROOT/scripts/setup-dev.sh:*)"
    )
  fi
  if [ "$PERMISSIVE_BASH_WRAPPERS" = "true" ]; then
    perms+=("Bash(bash -c:*)" "Bash(zsh -c:*)")
  fi
  printf '%s\n' "${perms[@]}"
}

# expected_hooks — emit the hook commands install.sh would register, one per
# line as `<event>\t<matcher>\t<command>` (matcher is `null` if unscoped).
# Tilde-aware dedup is the caller's job; this just enumerates intent.
expected_hooks() {
  printf '%s\t%s\t%s\n' \
    "PreToolUse"        "null"        "$HOME/.claude/hooks/approval-notifier.sh" \
    "PreToolUse"        "Bash"        "$HOME/.claude/scripts/forge-context.sh gate" \
    "PreToolUse"        "Write|Edit"  "$HOME/.claude/hooks/forge-vault-plan-guard.sh" \
    "PreCompact"        "null"        "$HOME/.claude/hooks/forge-compaction.sh pre" \
    "PostCompact"       "null"        "$HOME/.claude/hooks/forge-compaction.sh post" \
    "PostToolUse"       "null"        "$HOME/.claude/scripts/forge-context.sh post-tool" \
    "Stop"              "null"        "$HOME/.claude/scripts/forge-context.sh stop" \
    "SessionEnd"        "null"        "$HOME/.claude/hooks/forge-session-end.sh" \
    "UserPromptSubmit"  "null"        "$HOME/.claude/hooks/inject-current-time.sh"
}

# do_preview — read-only categorized diff of source vs installed state.
# Exits:
#   0 — in sync (no file changes, no settings additions pending)
#   1 — drift detected (changes would be applied by a normal install run)
#   2 — error (currently unused; reserved for future "can't read source" cases)
#
# Surfaces:
#   File-level: new (+), modified (~), removed (-)
#   Settings.json additions: permissions, hooks (computed from expected_*)
#
# Excluded from the diff (deliberately):
#   - forge.conf (user-mutable; install handles merge separately)
#   - shell-rc source line (line edit, not file ownership)
#   - vault git-init / hooks-opt-in / permissive-wrappers prompts (apply-time)
do_preview() {
  local manifest_old="$CLAUDE_DIR/.forge-manifest"
  local pairs_tmp old_tmp new_tmp
  pairs_tmp=$(mktemp)
  old_tmp=$(mktemp)
  new_tmp=$(mktemp)
  build_pairs > "$pairs_tmp"
  cut -f2 < "$pairs_tmp" > "$new_tmp"
  if [ -f "$manifest_old" ]; then
    sort "$manifest_old" > "$old_tmp"
  else
    : > "$old_tmp"
  fi

  local new_files=() mod_overwrite=() mod_preserve=() rm_files=()
  local src dst type policy
  while IFS=$'\t' read -r src dst type policy; do
    if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
      new_files+=("$dst")
    elif ! files_equal "$src" "$dst" "$type"; then
      if [ "$policy" = "preserve" ]; then
        mod_preserve+=("$dst")
      else
        mod_overwrite+=("$dst")
      fi
    fi
  done < "$pairs_tmp"

  # Removals = old manifest paths NOT in current build_pairs output, AND still
  # present on disk (paths the user already deleted shouldn't surface as "will
  # remove" — they're already gone).
  while IFS= read -r old_dst; do
    if [ -n "$old_dst" ] && ! grep -qxF "$old_dst" "$new_tmp"; then
      if [ -e "$old_dst" ] || [ -L "$old_dst" ]; then
        rm_files+=("$old_dst")
      fi
    fi
  done < "$old_tmp"

  # Settings.json additions
  local perms_missing=() hooks_missing=()
  if [ -f "$SETTINGS_FILE" ]; then
    local settings
    settings=$(cat "$SETTINGS_FILE")
    local perm
    while IFS= read -r perm; do
      [ -z "$perm" ] && continue
      if ! echo "$settings" | jq -e --arg p "$perm" '.permissions.allow // [] | index($p)' &>/dev/null; then
        perms_missing+=("$perm")
      fi
    done < <(expected_perms)
    local event matcher command
    while IFS=$'\t' read -r event matcher command; do
      [ -z "$event" ] && continue
      if ! echo "$settings" | jq -e --arg e "$event" --arg cmd "$command" --arg home "$HOME" \
        '.hooks[$e] // [] | .. | .command? // empty
         | (gsub($home; "~")) as $stored
         | ($cmd | gsub($home; "~")) as $incoming
         | select($stored == $incoming)' &>/dev/null 2>&1; then
        hooks_missing+=("$event|$matcher|$command")
      fi
    done < <(expected_hooks)
  else
    # No settings.json — everything would be added
    while IFS= read -r perm; do
      [ -n "$perm" ] && perms_missing+=("$perm")
    done < <(expected_perms)
    while IFS=$'\t' read -r event matcher command; do
      [ -n "$event" ] && hooks_missing+=("$event|$matcher|$command")
    done < <(expected_hooks)
  fi

  rm -f "$pairs_tmp" "$old_tmp" "$new_tmp"

  # ─── Print summary ───
  echo ""
  info "Preview of changes that install.sh would apply"
  if [ ! -f "$manifest_old" ]; then
    hint "No prior manifest at $manifest_old — treating as first install."
  fi
  echo ""

  local total_changes=$(( ${#new_files[@]} + ${#mod_overwrite[@]} + ${#mod_preserve[@]} + ${#rm_files[@]} + ${#perms_missing[@]} + ${#hooks_missing[@]} ))

  if [ ${#new_files[@]} -gt 0 ]; then
    printf "  ${GREEN}+ %d new file(s)${NC} — would install:\n" "${#new_files[@]}"
    for f in "${new_files[@]}"; do printf "      ${GREEN}+${NC} %s\n" "$f"; done
    echo ""
  fi
  if [ ${#mod_overwrite[@]} -gt 0 ]; then
    printf "  ${YELLOW}~ %d modified file(s)${NC} — would back up + overwrite:\n" "${#mod_overwrite[@]}"
    for f in "${mod_overwrite[@]}"; do printf "      ${YELLOW}~${NC} %s\n" "$f"; done
    hint "Backup naming: <file>.pre-update.<timestamp>"
    echo ""
  fi
  if [ ${#mod_preserve[@]} -gt 0 ]; then
    printf "  ${CYAN}≈ %d preserved file(s)${NC} — local differs from upstream; would write .upstream.<ts> sibling, leave local untouched:\n" "${#mod_preserve[@]}"
    for f in "${mod_preserve[@]}"; do printf "      ${CYAN}≈${NC} %s\n" "$f"; done
    hint "Sibling naming: <file>.upstream.<timestamp>"
    echo ""
  fi
  if [ ${#rm_files[@]} -gt 0 ]; then
    printf "  ${RED}- %d removed file(s)${NC} — no longer in source, would back up + delete:\n" "${#rm_files[@]}"
    for f in "${rm_files[@]}"; do printf "      ${RED}-${NC} %s\n" "$f"; done
    hint "Backup naming: <file>.pre-remove.<timestamp>"
    echo ""
  fi
  if [ ${#perms_missing[@]} -gt 0 ]; then
    printf "  ${CYAN}+ %d permission(s)${NC} — would add to settings.json:\n" "${#perms_missing[@]}"
    for p in "${perms_missing[@]}"; do printf "      ${CYAN}+${NC} %s\n" "$p"; done
    echo ""
  fi
  if [ ${#hooks_missing[@]} -gt 0 ]; then
    printf "  ${CYAN}+ %d hook(s)${NC} — would register in settings.json:\n" "${#hooks_missing[@]}"
    for h in "${hooks_missing[@]}"; do
      local hev="${h%%|*}"; local rest="${h#*|}"; local hmat="${rest%%|*}"; local hcmd="${rest#*|}"
      if [ "$hmat" = "null" ]; then
        printf "      ${CYAN}+${NC} %-16s %s\n" "$hev" "$hcmd"
      else
        printf "      ${CYAN}+${NC} %-16s [%s] %s\n" "$hev" "$hmat" "$hcmd"
      fi
    done
    echo ""
  fi

  if [ "$total_changes" -eq 0 ]; then
    ok "Forge install is in sync — nothing to do."
    return 0
  fi

  info "Summary: $total_changes change(s) pending."
  hint "Apply now:        ./install.sh"
  hint "Apply with prompt: ./install.sh --interactive"
  return 1
}

# remove_orphans — back up + delete files present in the previous manifest but
# absent from the current build_pairs output. Always-backup policy (per Q1 of
# the locked Slice 2 plan): even when the file is byte-identical to what we'd
# write, we keep a .pre-remove.<ts> copy. Cheap insurance against "I didn't
# realize that was important".
#
# Honors --dry-run by listing what would happen without touching files.
# Updates BACKUP_COUNT so the install summary reflects the backups.
remove_orphans() {
  local manifest_old="$CLAUDE_DIR/.forge-manifest"
  [ -f "$manifest_old" ] || return 0   # no prior manifest = nothing to remove

  local new_tmp orphans
  new_tmp=$(mktemp)
  build_manifest > "$new_tmp"
  orphans=()
  while IFS= read -r old_dst; do
    [ -z "$old_dst" ] && continue
    if ! grep -qxF "$old_dst" "$new_tmp"; then
      if [ -e "$old_dst" ] || [ -L "$old_dst" ]; then
        orphans+=("$old_dst")
      fi
    fi
  done < "$manifest_old"
  rm -f "$new_tmp"

  [ ${#orphans[@]} -eq 0 ] && return 0

  echo ""
  info "Removing ${#orphans[@]} file(s) no longer shipped by source..."
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local f backup
  for f in "${orphans[@]}"; do
    backup="${f}.pre-remove.${ts}"
    if [ "$DRY_RUN" = true ]; then
      printf "${DIM}    would back up + remove: %s${NC}\n" "$f"
      continue
    fi
    if [ -L "$f" ]; then
      # Symlinks: copy preserves target text via `cp -P`; rm removes the link.
      cp -P "$f" "$backup" 2>/dev/null || true
    elif [ -f "$f" ]; then
      cp "$f" "$backup"
    fi
    rm -f "$f"
    warn "Removed $(basename "$f") (backup: $(basename "$backup"))"
    BACKUP_COUNT=$((BACKUP_COUNT + 1))
  done
}

# ─── Detect repo root ────────────────────────────────────────────────────────
FORGE_ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$FORGE_ROOT/core" ] || [ ! -d "$FORGE_ROOT/adapters/claude-code" ]; then
  fail "Can't find Forge repo structure. Run this from the forge repo root."
fi

# ─── Path definitions ────────────────────────────────────────────────────────
# Hoisted above prereq checks + banner so the --preview / --interactive
# short-circuit (immediately below) can resolve manifest + source paths
# without running the full setup. Apply path also references these.
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
ADAPTER="$FORGE_ROOT/adapters/claude-code"
SKILLS_DIR="$CLAUDE_DIR/skills"
AGENTS_DIR="$CLAUDE_DIR/agents"

# ─── --preview / --interactive short-circuit ─────────────────────────────────
# Preview is the read-only path: resolve install state from forge.conf (no
# prompts, no writes), diff source vs installed, print categorized summary,
# exit. Interactive layers a single Y/n prompt on top and falls through to the
# normal apply flow on Y. Both must run BEFORE prereq checks and BEFORE the
# banner — preview deliberately requires no terminal, no jq prompt for missing
# packages, no vault setup. (jq IS required for the settings.json diff; if
# it's missing the preview surfaces fewer details but still exits cleanly.)
if [ "$PREVIEW" = true ] || [ "$INTERACTIVE" = true ]; then
  if [ ! -d "$CLAUDE_DIR" ]; then
    fail "~/.claude/ not found — Claude Code must be installed first."
  fi
  resolve_install_state
  # Capture do_preview's exit code explicitly — `if do_preview; then` swallows
  # the non-zero return (the `if` statement's own exit code is 0 when no branch
  # body executes), so we need the `|| true` + explicit capture to get the real
  # value while respecting `set -e`.
  preview_rc=0
  do_preview || preview_rc=$?
  if [ "$preview_rc" -eq 0 ]; then
    # In sync — nothing to do regardless of which flag was passed.
    exit 0
  fi
  if [ "$PREVIEW" = true ]; then
    exit "$preview_rc"
  fi
  # --interactive: prompt before applying
  echo ""
  apply_answer=$(prompt_or_default \
    "$(printf "${CYAN}[forge]${NC} Apply the changes above? [y/N]: ")" \
    "n")
  case "${apply_answer:-n}" in
    [Yy]*)
      info "Proceeding with install..."
      # Fall through to the normal apply flow below.
      ;;
    *)
      info "Aborted — no changes applied."
      exit 0
      ;;
  esac
fi

echo ""
if [ "$DRY_RUN" = true ]; then
  printf "${YELLOW}[forge] DRY RUN — no files will be modified${NC}\n"
fi
info "Installing Forge from $FORGE_ROOT"
echo ""

# ─── Prerequisites ───────────────────────────────────────────────────────────
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
  # Other keys (ONBOARDING_COMPLETE, WELLNESS_ENABLED, MAINTAINER_MODE, EOW_DAY,
  # MEETING_WINDOW_MIN, MODEL_*, VAULT_GIT_DECLINED) are left untouched.
  # Consumer code uses sensible defaults when keys are missing.
  set_conf_key VAULT_PATH "$VAULT_PATH"
  set_conf_key FORGE_REPO "$FORGE_ROOT"
  # MAINTAINER_MODE was introduced after some installs existed. If missing,
  # append the default (false) so the key is discoverable. If the user has
  # already set it, leave their value untouched.
  if ! grep -q "^MAINTAINER_MODE=" "$CLAUDE_DIR/forge.conf" 2>/dev/null; then
    echo "MAINTAINER_MODE=false" >> "$CLAUDE_DIR/forge.conf"
  fi
  # EOW_DAY (ISO day-of-week, Mon=1..Sun=7; Friday=5 default) was introduced
  # after some installs existed. If missing, append the default so the key is
  # discoverable. If the user has already set it, leave their value untouched.
  if ! grep -q "^EOW_DAY=" "$CLAUDE_DIR/forge.conf" 2>/dev/null; then
    echo "EOW_DAY=5" >> "$CLAUDE_DIR/forge.conf"
  fi
  # MEETING_WINDOW_MIN (minutes) was introduced after some installs existed.
  # Caps the look-ahead for wrap-up meeting awareness. If missing, append the
  # default (30). If the user has already set it, leave their value untouched.
  if ! grep -q "^MEETING_WINDOW_MIN=" "$CLAUDE_DIR/forge.conf" 2>/dev/null; then
    echo "MEETING_WINDOW_MIN=30" >> "$CLAUDE_DIR/forge.conf"
  fi
  # WELLNESS_DAY_START_HOURS (hours) was introduced after some installs existed.
  # Tiers the cold-start message: gaps >= this read as a fresh start (overnight,
  # weekend) rather than "break credited". Default 6h. If the user has already
  # set it, leave their value untouched.
  if ! grep -q "^WELLNESS_DAY_START_HOURS=" "$CLAUDE_DIR/forge.conf" 2>/dev/null; then
    echo "WELLNESS_DAY_START_HOURS=6" >> "$CLAUDE_DIR/forge.conf"
  fi
  # REPO_ROOTS — colon-separated list of directories scanned for project repos
  # by forge-context.sh's get_project_dir. Introduced after some installs
  # existed (the original fallback was a hardcoded maintainer-specific path
  # inside forge-context.sh — see hardcoded-paths-guard-test). If missing,
  # infer from FORGE_REPO's grandparent so the existing layout is preserved
  # without a manual edit. Users with non-env-nested layouts (flat ROOT/project/)
  # may want to edit forge.conf and replace with the correct ROOT.
  if ! grep -q "^REPO_ROOTS=" "$CLAUDE_DIR/forge.conf" 2>/dev/null; then
    INFERRED_REPO_ROOTS="$(dirname "$(dirname "$FORGE_ROOT")")"
    echo "REPO_ROOTS=$INFERRED_REPO_ROOTS" >> "$CLAUDE_DIR/forge.conf"
    ok "REPO_ROOTS inferred and added: $INFERRED_REPO_ROOTS (edit forge.conf if your project layout differs)"
  fi
  ok "forge.conf updated (preserved existing user-set values)"
else
  # First install — write full template with defaults.
  cat > "$CLAUDE_DIR/forge.conf" <<EOF
# Forge configuration — written by install.sh
VAULT_PATH=$VAULT_PATH
FORGE_REPO=$FORGE_ROOT
ONBOARDING_COMPLETE=false
WELLNESS_ENABLED=false

# MAINTAINER_MODE distinguishes Forge end-users from Forge maintainers (people
# extending Forge itself). Default false = end-user mode: Petra suppresses
# meta-work invitations (friction-log writes, decisions/ curation, INDEX.md
# maintenance, vault hygiene, forge-internal audits) from entry summaries and
# checkpoint Next-Steps. Set to true if you're working on Forge itself and
# want those surfaces surfaced as actionable threads.
MAINTAINER_MODE=false

# Cold-start threshold (hours). When session entry detects no Forge signal for
# longer than this, Petra runs wellness-reset.sh --full-reset before the entry
# summary. Default 4h covers lunch + a meeting block; tune up if you typically
# return to deep work after shorter pauses, down if you want stricter resets.
WELLNESS_COLD_START_HOURS=4

# Day-start threshold (hours). Gaps at or above this are treated as a fresh start
# (overnight, weekend, multi-day) and the cold-start message switches from
# "break clock zeroed" to "fresh start" framing. Independent from
# WELLNESS_COLD_START_HOURS — that gates whether the message fires at all; this
# one tiers the message wording. Default 6h: within-workday gaps read as breaks
# credited, longer gaps read as a new session.
WELLNESS_DAY_START_HOURS=6

# EOW_DAY = ISO day-of-week treated as end-of-week (Mon=1..Sun=7). Default 5
# (Friday). On EOW_DAY, the eod_window/past_eod states emitted by
# \`forge-context.sh wrap-up-state\` are upgraded to eow_window/past_eow, which
# trigger weekly-wrap behavior in addition to the daily-wrap surface.
EOW_DAY=5

# MEETING_WINDOW_MIN = look-ahead horizon (minutes) for the
# \`forge-context.sh next-meeting\` subcommand. At wrap-up moments Petra queries
# this window to detect imminent calendar interruptions; meetings further out
# are filtered out as not actionable for the current wrap-up decision.
MEETING_WINDOW_MIN=30

# REPO_ROOTS = colon-separated list of directories that contain your project
# repos. Scanned by forge-context.sh's get_project_dir at depth 1 (flat layout:
# ROOT/project/) and depth 2 (env-nested: ROOT/env/project/), case-insensitively.
# Inferred at first install as the grandparent of FORGE_REPO (preserves
# existing layouts without a manual edit). Edit if your project layout differs
# (e.g. multiple roots: REPO_ROOTS=~/work:~/personal:~/oss).
REPO_ROOTS=$(dirname "$(dirname "$FORGE_ROOT")")

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

# Vault templates are A2-preserve: starting points users may customize.
# safe_cp with `preserve` policy: install if missing, no-op if matches src,
# write upstream as `.upstream.<ts>` sibling if user diverged.
for tpl in "$FORGE_ROOT/core/vault-templates/"*; do safe_cp "$tpl" "$VAULT_PATH/_templates/" preserve; done
ok "Vault structure at $VAULT_PATH"

# ─── Obsidian draft-capture hint (Slice A of user-draft-task-capture) ────────
# If the vault has an Obsidian config dir, the user is using Obsidian — point
# them at the docs page that walks through the optional Templater + Folder
# Templates setup for 5-second draft capture. Silent when Obsidian isn't
# detected (CLI-only users get no noise).
if [ -d "$VAULT_PATH/.obsidian" ]; then
  hint "For optional 5-second manual draft capture from Obsidian, see"
  hint "    $FORGE_ROOT/docs/obsidian-draft-capture.md"
  hint "    (Templater + Folder Templates wire-up; the draft template is already at $VAULT_PATH/_templates/draft.md)"
fi

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
    # Tty empty: 'Y' to match the [Y/n] display convention.
    # Non-tty: 'n' (skip init — too consequential to auto-init silently in CI).
    git_init_answer=$(prompt_or_default \
      "$(printf "        Initialize git in the vault now? [Y/n]: ")" \
      "Y" "n")
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

# ─── Offer post-merge nudge hook (opt-in) ────────────────────────────────────
# A `.githooks/post-merge` ships in this repo. Git won't run it unless the user
# explicitly points `core.hooksPath` at it — that's the security model for hooks
# living in source-controlled directories. We prompt once; the flag in
# forge.conf keeps subsequent installs silent.
#
# When enabled: after `git pull` (or any merge), the hook prints a one-liner if
# install.sh or any path under adapters/ or core/ changed, reminding the user
# to re-run install.sh.

if git -C "$FORGE_ROOT" rev-parse --git-dir &>/dev/null; then
  existing_hooks_path=$(git -C "$FORGE_ROOT" config --get core.hooksPath 2>/dev/null || true)
  if [ -n "$existing_hooks_path" ]; then
    : # already configured (by user or previous install) — leave alone
  elif grep -q '^FORGE_HOOKS_DECLINED=true' "$CLAUDE_DIR/forge.conf" 2>/dev/null; then
    : # user previously declined — silent skip
  elif [ "$DRY_RUN" = true ]; then
    info "Would prompt: enable .githooks/post-merge nudge after git pull"
  else
    echo ""
    printf "${CYAN}[forge]${NC} A repo-side post-merge hook is available.\n"
    printf "        After \`git pull\` updates installed files, it prints a\n"
    printf "        one-liner reminding you to re-run \`./install.sh\`.\n"
    printf "        Opt-in by setting \`core.hooksPath\` to \`.githooks\` in this repo.\n"
    # Tty empty: 'Y' to match the [Y/n] display convention.
    # Non-tty: 'n' (don't silently flip core.hooksPath under a CI job).
    hooks_answer=$(prompt_or_default \
      "$(printf "        Enable now? [Y/n]: ")" \
      "Y" "n")
    case "${hooks_answer:-Y}" in
      [Yy]*|"")
        run git -C "$FORGE_ROOT" config core.hooksPath .githooks
        ok "core.hooksPath = .githooks (post-merge nudge enabled for this repo)"
        ;;
      *)
        if [ -t 0 ]; then
          set_conf_key FORGE_HOOKS_DECLINED true
        fi
        info "Hook left disabled per user choice."
        ;;
    esac
  fi
fi

# ─── Copy skills ─────────────────────────────────────────────────────────────
# ADAPTER / SKILLS_DIR defined alongside other paths near the top of this file.

echo ""
info "Installing skills..."

# Core skills
for skill in forge forge-checkpoint forge-exit forge-weekly forge-audit forge-audit-permissions forge-vault-sync keeper refiner plan-reviewer; do
  run mkdir -p "$SKILLS_DIR/$skill"
  install_skill_md "$ADAPTER/skills/$skill/SKILL.md" "$SKILLS_DIR/$skill/SKILL.md"
done
ok "Core skills (forge, forge-checkpoint, forge-exit, forge-weekly, forge-audit, forge-audit-permissions, forge-vault-sync, keeper, refiner, plan-reviewer)"

# Symlink core references into forge skill — A2 preserve policy:
# users may copy a ref to a real file and edit it (e.g. tweaking
# wellness-cold-start thresholds). install_symlink with preserve leaves
# those copies alone and writes a `.upstream.<ts>` sibling for diff.
run mkdir -p "$SKILLS_DIR/forge/references"
for ref in lifecycle.md vocabulary.md wellness-awareness.md script-replacement-patterns.md friction-classifier.md onboarding.md agent-teams-mode.md wellness-cold-start.md prose-wind-down.md wrap-up-state.md; do
  install_symlink "$FORGE_ROOT/core/references/$ref" "$SKILLS_DIR/forge/references/$ref" preserve
done
ok "References symlinked (updates with git pull; A2-preserve for local edits)"

# Symlink Quartermaster reference into forge-weekly skill (scoped — only loaded
# when /forge-weekly fires, keeps weekly-only persona out of /forge entry cost).
# A2 preserve policy — same logic as the forge skill refs above.
run mkdir -p "$SKILLS_DIR/forge-weekly/references"
install_symlink "$FORGE_ROOT/core/references/quartermaster.md" "$SKILLS_DIR/forge-weekly/references/quartermaster.md" preserve
ok "Quartermaster reference symlinked into forge-weekly"

# Wellness coach files (always copied — hooks wired during onboarding)
WC_SRC="$ADAPTER/modules/wellness-coach"
WC_DST="$SKILLS_DIR/wellness-coach"

run mkdir -p "$WC_DST/hooks" "$WC_DST/scripts" "$WC_DST/src"
safe_cp "$WC_SRC/skills/wellness-coach/SKILL.md" "$WC_DST/SKILL.md"
safe_cp "$WC_SRC/README.md" "$WC_DST/"
for hook in "$WC_SRC/hooks/"*.py; do safe_cp "$hook" "$WC_DST/hooks/"; done
for script in "$WC_SRC/scripts/"*; do
  # Skip subdirs (e.g. tests/) — only top-level script files get installed at runtime
  [ -f "$script" ] && safe_cp "$script" "$WC_DST/scripts/"
done
safe_cp "$WC_SRC/src/screen_state.c" "$WC_DST/src/"
run chmod +x "$WC_DST/scripts/"*.sh

# Symlink wellness-coach references (lazy-loaded by SKILL.md stubs) — A2 preserve.
run mkdir -p "$WC_DST/references"
for ref in onboarding.md conflict-resolution.md window-isolation.md personas.md auto-detected-tiers.md strike-conversation.md; do
  install_symlink "$WC_SRC/references/$ref" "$WC_DST/references/$ref" preserve
done
ok "Wellness coach files (activation offered during first /forge session)"

# ─── Copy agent definitions ──────────────────────────────────────────────────
echo ""
info "Installing agent definitions..."

# AGENTS_DIR defined alongside other paths near the top of this file.
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
safe_cp "$ADAPTER/scripts/forge-classify-friction.sh" "$CLAUDE_DIR/scripts/"
safe_cp "$ADAPTER/scripts/forge-gap-since-last-signal.sh" "$CLAUDE_DIR/scripts/"
safe_cp "$ADAPTER/scripts/forge-calendar.sh" "$CLAUDE_DIR/scripts/"
safe_cp "$ADAPTER/scripts/forge-cost-snapshot.sh" "$CLAUDE_DIR/scripts/"
safe_cp "$ADAPTER/scripts/statusline.sh" "$CLAUDE_DIR/statusline.sh" preserve

run chmod +x "$CLAUDE_DIR/hooks/forge-compaction.sh" \
             "$CLAUDE_DIR/hooks/approval-notifier.sh" \
             "$CLAUDE_DIR/hooks/forge-vault-plan-guard.sh" \
             "$CLAUDE_DIR/hooks/forge-session-end.sh" \
             "$CLAUDE_DIR/hooks/inject-current-time.sh" \
             "$CLAUDE_DIR/scripts/forge-context.sh" \
             "$CLAUDE_DIR/scripts/forge-permission-lint.sh" \
             "$CLAUDE_DIR/scripts/forge-classify-friction.sh" \
             "$CLAUDE_DIR/scripts/forge-gap-since-last-signal.sh" \
             "$CLAUDE_DIR/scripts/forge-calendar.sh" \
             "$CLAUDE_DIR/scripts/forge-cost-snapshot.sh" \
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

# Permissive shell-wrapper defaults (tester item #6) — opt-in via forge.conf.
# Off by default: these patterns allow ANY command passed to the wrapper once
# the prefix matches (Claude Code Bash matcher grants the WHOLE command —
# see core/references/permission-patterns.md pitfall #2). Power users who
# accept that tradeoff opt in to reduce permission-prompt friction during
# multi-step setup steps (Forge install, wellness-coach setup, gws-auth
# recovery, etc.).
PERMISSIVE_BASH_WRAPPERS="${PERMISSIVE_BASH_WRAPPERS:-false}"
if [ -f "$CLAUDE_DIR/forge.conf" ] && grep -qE '^PERMISSIVE_BASH_WRAPPERS=' "$CLAUDE_DIR/forge.conf" 2>/dev/null; then
  PERMISSIVE_BASH_WRAPPERS=$(grep -E '^PERMISSIVE_BASH_WRAPPERS=' "$CLAUDE_DIR/forge.conf" | head -1 | cut -d= -f2)
elif [ "$DRY_RUN" = true ]; then
  info "Would prompt: ship permissive shell-wrapper defaults (bash -c, zsh -c)?"
else
  echo ""
  printf "${CYAN}[forge]${NC} Permissive shell-wrapper defaults reduce prompt friction during multi-step setup steps.\n"
  printf "        Adds: Bash(bash -c:*), Bash(zsh -c:*)\n"
  printf "        Tradeoff: each pattern allows ANY command inside the wrapper.\n"
  printf "        See core/references/permission-patterns.md for the matcher behavior.\n"
  printf "        Recommended only if you already accept this tradeoff. Default: NO.\n"
  permissive_answer=$(prompt_or_default \
    "$(printf "        Add permissive wrappers? [y/N]: ")" \
    "n")
  case "${permissive_answer:-n}" in
    [Yy]*) PERMISSIVE_BASH_WRAPPERS=true;;
    *)     PERMISSIVE_BASH_WRAPPERS=false;;
  esac
  # Persist only for interactive answers (-t 0) — non-tty fallback isn't a real choice.
  if [ -t 0 ]; then
    set_conf_key PERMISSIVE_BASH_WRAPPERS "$PERMISSIVE_BASH_WRAPPERS"
  fi
fi

PERMS_TO_ADD=(
  # Forge scripts
  "Bash($HOME/.claude/scripts/forge-context.sh:*)"
  "Bash($HOME/.claude/scripts/forge-permission-lint.sh:*)"
  "Bash($HOME/.claude/scripts/forge-classify-friction.sh:*)"
  "Bash($HOME/.claude/scripts/forge-gap-since-last-signal.sh:*)"
  "Bash($HOME/.claude/scripts/forge-calendar.sh:*)"
  "Bash($HOME/.claude/scripts/forge-calendar.sh *)"
  "Bash(~/.claude/scripts/forge-calendar.sh *)"
  "Bash($HOME/.claude/scripts/forge-cost-snapshot.sh:*)"
  "Bash($HOME/.claude/statusline.sh:*)"
  # Forge hooks
  "Bash($HOME/.claude/hooks/forge-compaction.sh:*)"
  "Bash($HOME/.claude/hooks/approval-notifier.sh:*)"
  "Bash($HOME/.claude/hooks/forge-vault-plan-guard.sh:*)"
  "Bash($HOME/.claude/hooks/forge-session-end.sh:*)"
  "Bash($HOME/.claude/hooks/inject-current-time.sh:*)"
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

# Conditional: maintainer mode — allowlist dev-time invocations against the
# source-of-truth repo paths so working ON forge doesn't hit per-call prompts.
# End users (MAINTAINER_MODE=false, the default) don't have the forge repo at
# these paths anyway; the patterns would never match for them. Gating keeps
# end-user settings.json visually clean. Source: bash-allowlist-audit (PR #65).
INSTALL_MAINTAINER_MODE="false"
if [ -f "$CLAUDE_DIR/forge.conf" ]; then
  INSTALL_MAINTAINER_MODE="$(grep '^MAINTAINER_MODE=' "$CLAUDE_DIR/forge.conf" 2>/dev/null | head -1 | cut -d= -f2 || true)"
  [ -z "$INSTALL_MAINTAINER_MODE" ] && INSTALL_MAINTAINER_MODE="false"
fi
if [ "$INSTALL_MAINTAINER_MODE" = "true" ]; then
  PERMS_TO_ADD+=(
    "Bash($FORGE_ROOT/adapters/claude-code/scripts/*)"
    "Bash($FORGE_ROOT/adapters/claude-code/hooks/*)"
    "Bash($FORGE_ROOT/adapters/claude-code/modules/wellness-coach/scripts/*)"
    "Bash(python3:$FORGE_ROOT/adapters/claude-code/modules/wellness-coach/hooks/*)"
    "Bash($FORGE_ROOT/scripts/lint/no-hardcoded-paths.sh:*)"
    "Bash($FORGE_ROOT/scripts/setup-dev.sh:*)"
  )
fi

# Conditional: permissive shell wrappers (tester item #6, opt-in above)
if [ "$PERMISSIVE_BASH_WRAPPERS" = "true" ]; then
  PERMS_TO_ADD+=(
    "Bash(bash -c:*)"
    "Bash(zsh -c:*)"
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
# Some upstream installers ship `Bash(*foo*)`
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
    hint "These typically come from a previous third-party installer."
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

safe_cp "$TMUX_CONF_SOURCE" "$TMUX_CONF_FILE" preserve
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

# ─── Remove orphans + write manifest ─────────────────────────────────────────
# remove_orphans deletes (with backup) files present in the previous manifest
# but absent from the current build_pairs output — i.e. files install.sh used
# to ship and no longer does. Must run BEFORE manifest write so the new
# manifest reflects post-removal state.
#
# Manifest snapshot: atomic .tmp + mv. Read by `--preview` on the next run to
# compute removals (files in the old manifest the current run wouldn't write).
# Lives at $CLAUDE_DIR/.forge-manifest, sorted, one absolute path per line.
# Plain text on purpose — diffable with `diff`, greppable, easy to hand-audit.
remove_orphans

if [ "$DRY_RUN" = false ]; then
  manifest="$CLAUDE_DIR/.forge-manifest"
  build_manifest > "${manifest}.tmp" && mv "${manifest}.tmp" "$manifest"
  manifest_count=$(wc -l < "$manifest" | tr -d ' ')
  ok "Manifest written ($manifest_count paths tracked at .forge-manifest)"
fi

# ─── A2-preserve file validation ─────────────────────────────────────────────
# Warn (don't fail) if any A2-preserve file has a detectable syntax error.
# Catches smoke-test residue, half-saved edits, etc. — see function KDoc.
# Skipped on dry-run (we never wrote anything, nothing to validate).
if [ "$DRY_RUN" = false ]; then
  validate_preserved_a2_files
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
echo "  Core skills:   forge, forge-checkpoint, forge-exit, forge-audit, forge-audit-permissions,"
echo "                 forge-vault-sync, keeper, refiner, plan-reviewer"
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
if [ "$PRUNED_SIBLING_COUNT" -gt 0 ]; then
  echo "  Pruned:        $PRUNED_SIBLING_COUNT stale .upstream.<ts> sibling(s) — kept the latest per file"
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
