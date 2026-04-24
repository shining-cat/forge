#!/bin/bash
# Forge compaction hooks — PreCompact and PostCompact
# Ensures Forge state is checkpointed before compaction and restored after.
#
# Usage:
#   forge-compaction.sh pre   — called by PreCompact hook
#   forge-compaction.sh post  — called by PostCompact hook

MARKER="$HOME/.claude/forge-active"
PHASE="${1:-}"

if [ ! -f "$MARKER" ]; then
  # Forge not running — nothing to do
  exit 0
fi

PROJECT=$(head -1 "$MARKER" 2>/dev/null | tr -d '[:space:]')

# Empty marker = Forge deactivated (exit wrote empty file) — nothing to do
if [ -z "$PROJECT" ]; then
  exit 0
fi

if [ "$PHASE" = "pre" ]; then
  # Check checkpoint staleness — warn but don't block
  # PreCompact fires when context is nearly full, so requiring Claude actions here creates deadlock
  CHECKPOINT_DIR="$HOME/__DEV/Vault"

  # Determine which checkpoint file to check based on project
  case "$PROJECT" in
    FINN|DBA|TORI|BLOCKET)
      CHECKPOINT_FILE="$CHECKPOINT_DIR/SCHIBSTED/$PROJECT/current-checkpoint.md"
      ;;
    Forge|forge)
      CHECKPOINT_FILE="$CHECKPOINT_DIR/PERSO/forge/current-checkpoint.md"
      ;;
    *)
      CHECKPOINT_FILE="$CHECKPOINT_DIR/PERSO/$PROJECT/current-checkpoint.md"
      ;;
  esac

  NEEDS_WARNING=false
  if [ -f "$CHECKPOINT_FILE" ]; then
    if [ "$(uname)" = "Darwin" ]; then
      FILE_MOD=$(stat -f %m "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
    else
      FILE_MOD=$(stat -c %Y "$CHECKPOINT_FILE" 2>/dev/null || echo 0)
    fi
    NOW=$(date +%s)
    AGE=$(( (NOW - FILE_MOD) / 60 ))

    if [ "$AGE" -ge 2 ]; then
      NEEDS_WARNING=true
    fi
  else
    NEEDS_WARNING=true
  fi

  if [ "$NEEDS_WARNING" = true ]; then
    # Warn but allow compaction — context is constrained, can't safely checkpoint now
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreCompact","systemMessage":"[Keeper] Checkpoint is stale (project: $PROJECT). After compaction, write a checkpoint while context is clear."}}
EOF
  fi

  # Always allow compaction — blocking here creates deadlock
  # Stop hook already enforces checkpoint discipline with 60min hard block
  exit 0

elif [ "$PHASE" = "post" ]; then
  # After compaction — tell Claude to reload Forge
  cat <<EOF
{"systemMessage":"Forge was active before compaction (project: $PROJECT). Re-invoke the /forge skill now to restore full session rules, then read current-checkpoint.md to reorient."}
EOF
  exit 0
fi
