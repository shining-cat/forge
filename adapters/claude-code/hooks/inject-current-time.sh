#!/usr/bin/env bash
# UserPromptSubmit hook: prepends current local time + Forge header reminder.
#
# Two-line injection when Forge is active for a project:
#   [Current local time: 2026-05-19 16:09 CEST]
#   [Forge active for PERSO/forge — begin your response with: `[Forge: PERSO/forge | 16:09]`]
#
# Time-only injection otherwise (Forge inactive, pending, or deactivated):
#   [Current local time: 2026-05-19 16:09 CEST]
#
# Eliminates two recurring failures:
#   1. Time-guessing — Claude estimating elapsed time from checkpoint stamps
#      and step-duration guesses, often wrong by tens of minutes.
#   2. Header-prefix drift — Claude forgetting to begin Forge responses with
#      the `[Forge: ENV/Project | HH:MM]` block header. The reminder line puts
#      the literal expected prefix in front of Claude every turn so there is
#      no assembly step ("look up time + look up project + format the string")
#      to forget.
#
# Cost: ~3–5ms per turn (one date call + a small grep/sed pipeline when Forge
# is active). Reliability: 100% — Claude sees the actual time + the actual
# project from the marker; nothing is inferred.
#
# Format mirrors the system-reminder style so Claude treats it as authoritative.

TIME_FULL=$(date '+%Y-%m-%d %H:%M %Z')
TIME_HM=$(date '+%H:%M')

echo "[Current local time: $TIME_FULL]"

# ─── Forge header reminder (only when marker indicates an active project) ────

FORGE_CONF="$HOME/.claude/forge.conf"
[ -f "$FORGE_CONF" ] || exit 0

VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
[ -n "$VAULT_PATH" ] || exit 0

MARKER="$VAULT_PATH/_shared/forge-active"
[ -f "$MARKER" ] || exit 0

MARKER_CONTENT=$(cat "$MARKER" 2>/dev/null)
[ -n "$MARKER_CONTENT" ] || exit 0                  # empty → deactivated
[ "$MARKER_CONTENT" = "__pending__" ] && exit 0     # launching, no project yet

# Extract project from JSON marker. Tolerates optional whitespace around the colon.
# Legacy plain-string marker (just a project name) is not matched here — those
# fall through to exit 0 below, which is fine: legacy markers predate this hook
# and treating them as "no header reminder" is the safe default.
PROJECT=$(echo "$MARKER_CONTENT" | sed -n 's/.*"project"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$PROJECT" ] || exit 0

# Resolve ENV by finding the project folder under vault env subdirs.
# Project lives at $VAULT_PATH/$PROJECT_ENV/$PROJECT/ — env is the parent dir.
PROJECT_ENV=""
for env_dir in "$VAULT_PATH"/*/; do
    [ -d "$env_dir" ] || continue                   # nullglob-safe
    env_name=$(basename "$env_dir")
    [[ "$env_name" == _* ]] && continue             # skip meta dirs (_shared, _templates, _meta)
    if [ -d "$env_dir$PROJECT" ]; then
        PROJECT_ENV="$env_name"
        break
    fi
done

if [ -n "$PROJECT_ENV" ]; then
    HEADER_PREFIX="[Forge: $PROJECT_ENV/$PROJECT | $TIME_HM]"
else
    # ENV not resolvable (project not yet scaffolded under any env dir).
    # Fall back to project-only — still useful, just missing the ENV prefix.
    HEADER_PREFIX="[Forge: $PROJECT | $TIME_HM]"
fi

echo "[Forge active for $PROJECT — begin your response with: \`$HEADER_PREFIX\`]"
