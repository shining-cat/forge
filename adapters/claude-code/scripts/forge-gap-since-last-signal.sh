#!/bin/bash
# forge-gap-since-last-signal.sh — answers "seconds since last Forge work signal"
#
# Slice 1 of the unified gap-detection primitive
# (task: 2026-05-22-forge-gap-since-last-work-signal).
#
# Consumers read this number to decide things like:
#   - whether wellness should auto-credit a break on session entry (cold start)
#   - whether Petra's banner should say "Anvil's warm" or "Cold start — Forge idle for Nh"
#   - whether Keeper's stale-checkpoint math should treat a 13h-old checkpoint as
#     stale (no, if the user was Forge-idle for 14h)
#
# Signal sources (max() across all that exist):
#   - $VAULT_PATH/_shared/current-checkpoint.md           mtime
#   - $VAULT_PATH/_shared/forge-active                    mtime (only when JSON, not __pending__/empty)
#   - $VAULT_PATH/*/*/current-checkpoint.md               mtime (every project, every env)
#   - $VAULT_PATH/*/*/braindump.md                        mtime (every project, every env)
#   - vault git: `git log -1 --format=%ct`                most recent commit timestamp
#
# Wake/boot (kern.waketime, kern.boottime on macOS) are NOT counted as signals —
# the user being awake is not Forge activity. They are surfaced in --verbose
# output for context only, so consumers can decide whether to treat off-machine
# time specially.
#
# Output (default): one integer — seconds since most-recent signal.
# Output (--verbose): per-source breakdown + human-readable summary.
#
# Brand-new Forge install (no signals at all): emits 999999999 (~31y) as a
# sentinel. Consumers compare numerically; treat huge values as "first run".
#
# Exit 0 on success. Non-zero only on hard failure (no forge.conf, no VAULT_PATH).

set -euo pipefail

SENTINEL_NO_SIGNALS=999999999

FORGE_CONF="${FORGE_CONF_OVERRIDE:-$HOME/.claude/forge.conf}"
if [ ! -f "$FORGE_CONF" ]; then
  echo "[forge-gap] ERROR: forge.conf not found at $FORGE_CONF" >&2
  exit 1
fi
VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
if [ -z "$VAULT_PATH" ]; then
  echo "[forge-gap] ERROR: VAULT_PATH not set in $FORGE_CONF" >&2
  exit 1
fi

VERBOSE=false
case "${1:-}" in
  --verbose|-v) VERBOSE=true ;;
  "") ;;
  *) echo "[forge-gap] ERROR: unknown arg '$1' (use --verbose or no args)" >&2; exit 1 ;;
esac

NOW=$(date +%s)

# Portable mtime extraction (BSD/GNU stat). Echoes 0 if file missing or unreadable.
mtime() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return; }
  stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0
}

# Track per-source { name, mtime } for the verbose breakdown.
# Parallel arrays — bash 3 (default macOS) has no associative arrays.
SOURCES_NAME=()
SOURCES_MTIME=()

add_source() {
  local name="$1" m="$2"
  # Drop zero (missing file) and future-dated (clock skew) values.
  if [ "$m" -gt 0 ] && [ "$m" -le "$NOW" ]; then
    SOURCES_NAME+=("$name")
    SOURCES_MTIME+=("$m")
  fi
}

# 1. Shared cross-project checkpoint
add_source "_shared/current-checkpoint.md" "$(mtime "$VAULT_PATH/_shared/current-checkpoint.md")"

# 2. forge-active marker — only count when it holds a real JSON marker.
#    Empty / __pending__ / unreadable contribute nothing.
MARKER_FILE="$VAULT_PATH/_shared/forge-active"
if [ -f "$MARKER_FILE" ]; then
  marker_text=$(cat "$MARKER_FILE" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$marker_text" in
    ""|"__pending__") ;;
    *)
      # Try parse as JSON (the new session-isolated form). Plain-string legacy
      # markers also count — they represent a real past activation, just
      # without session-id metadata.
      if echo "$marker_text" | jq -e '.session_id' >/dev/null 2>&1 || [ -n "$marker_text" ]; then
        add_source "_shared/forge-active" "$(mtime "$MARKER_FILE")"
      fi
      ;;
  esac
fi

# 3. + 4. Every per-project checkpoint and braindump under VAULT_PATH/*/*/
#    Glob is project-agnostic by design — a write in PROJ-A is a Forge signal
#    even when we're now in PROJ-B.
shopt -s nullglob
for cp in "$VAULT_PATH"/*/*/current-checkpoint.md; do
  rel="${cp#$VAULT_PATH/}"
  add_source "$rel" "$(mtime "$cp")"
done
for bd in "$VAULT_PATH"/*/*/braindump.md; do
  rel="${bd#$VAULT_PATH/}"
  add_source "$rel" "$(mtime "$bd")"
done
shopt -u nullglob

# 5. Vault git: most recent commit. Silently skip if not a git repo or empty.
if [ -d "$VAULT_PATH/.git" ]; then
  git_ts=$(git -C "$VAULT_PATH" log -1 --format=%ct 2>/dev/null || echo 0)
  add_source "vault-git: last commit" "${git_ts:-0}"
fi

# Find the most recent signal across all sources.
LATEST_MTIME=0
LATEST_NAME="(none)"
i=0
while [ "$i" -lt "${#SOURCES_MTIME[@]}" ]; do
  m="${SOURCES_MTIME[$i]}"
  if [ "$m" -gt "$LATEST_MTIME" ]; then
    LATEST_MTIME="$m"
    LATEST_NAME="${SOURCES_NAME[$i]}"
  fi
  i=$((i + 1))
done

if [ "$LATEST_MTIME" -eq 0 ]; then
  # No signals at all — brand-new install or fully-empty vault.
  GAP_SECONDS="$SENTINEL_NO_SIGNALS"
else
  GAP_SECONDS=$((NOW - LATEST_MTIME))
fi

if [ "$VERBOSE" = false ]; then
  echo "$GAP_SECONDS"
  exit 0
fi

# --verbose: per-source breakdown + human summary + informational wake/boot.

echo "=== Forge gap-since-last-signal ==="
echo "Now:    $(date -r "$NOW" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$NOW" '+%Y-%m-%dT%H:%M:%S%z')"

if [ "$LATEST_MTIME" -eq 0 ]; then
  echo "Gap:    no signals found (sentinel ${SENTINEL_NO_SIGNALS}s)"
  echo "Latest: (none)"
else
  echo "Gap:    ${GAP_SECONDS}s ($((GAP_SECONDS / 60))m / $((GAP_SECONDS / 3600))h)"
  echo "Latest: $LATEST_NAME @ $(date -r "$LATEST_MTIME" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$LATEST_MTIME" '+%Y-%m-%dT%H:%M:%S%z')"
fi
echo ""
echo "--- Per-source signals (mtime desc) ---"
if [ "${#SOURCES_NAME[@]}" -eq 0 ]; then
  echo "(no signal sources found)"
else
  # Print sorted by mtime desc.
  i=0
  while [ "$i" -lt "${#SOURCES_MTIME[@]}" ]; do
    echo "${SOURCES_MTIME[$i]}|${SOURCES_NAME[$i]}"
    i=$((i + 1))
  done | sort -rn -t'|' -k1 | while IFS='|' read -r m name; do
    age=$((NOW - m))
    printf "  %-50s  age=%6ds  (%s)\n" "$name" "$age" "$(date -r "$m" '+%Y-%m-%dT%H:%M' 2>/dev/null || date -d "@$m" '+%Y-%m-%dT%H:%M')"
  done
fi

# Informational only — wake/boot don't shorten the gap (Forge wasn't running
# while the mac was asleep/off). Surfaced here so consumers can decide
# whether off-machine time deserves special handling.
if [ "$(uname -s)" = "Darwin" ]; then
  echo ""
  echo "--- macOS wake/boot (informational, not counted) ---"
  wake=$(sysctl -n kern.waketime 2>/dev/null | awk -F'[ =,]+' '/sec/{for(i=1;i<=NF;i++) if($i=="sec") {print $(i+1); exit}}')
  boot=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[ =,]+' '/sec/{for(i=1;i<=NF;i++) if($i=="sec") {print $(i+1); exit}}')
  if [ -n "$wake" ] && [ "$wake" -gt 0 ] && [ "$wake" -le "$NOW" ]; then
    echo "  wake:  age=$((NOW - wake))s  ($(date -r "$wake" '+%Y-%m-%dT%H:%M' 2>/dev/null))"
  fi
  if [ -n "$boot" ] && [ "$boot" -gt 0 ] && [ "$boot" -le "$NOW" ]; then
    echo "  boot:  age=$((NOW - boot))s  ($(date -r "$boot" '+%Y-%m-%dT%H:%M' 2>/dev/null))"
  fi
fi
