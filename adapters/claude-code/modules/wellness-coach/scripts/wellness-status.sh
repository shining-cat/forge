#!/bin/bash
# wellness-status.sh — emit compact wellness chips for the statusline, or
# run --diagnose to audit the Tier-2 activity monitor installation.
#
# Modes:
#   (no args)    — statusline chips. Soft-fails to empty output on any error.
#   --diagnose   — print a human-readable health report for the activity monitor.
#                  Exits 0 if all checks pass, 1 if any fail.
#
# Chip semantics:
#   🙆  — forward-looking schedule marker for the next micro-break reminder.
#         NOT a compliance signal — there's no signal saying "user stretched."
#         Always shows non-negative minutes; never "due", never red.
#   ☕  — real compliance signal for the next real break.
#         Backed by auto-detected break logic (system wake, activity monitor).
#         Can show "due" and triggers the chip color (yellow/red).
#
# Chip output formats:
#   "<color>🙆 12m  ☕ 38m\033[0m"           — normal state, color from break only
#   "<color>🙆 12m  ☕ due\033[0m"           — break overdue
#   "\033[31m⚠️ on strike\033[0m"            — strike active

# ----- diagnose mode --------------------------------------------------------

if [ "${1:-}" = "--diagnose" ]; then
    # Colors: only when stdout is a TTY.
    if [ -t 1 ]; then
        C_OK="\033[32m"; C_FAIL="\033[31m"; C_WARN="\033[33m"; C_DIM="\033[2m"; C_RST="\033[0m"
    else
        C_OK=""; C_FAIL=""; C_WARN=""; C_DIM=""; C_RST=""
    fi
    FAILED=0

    pass() { printf "  ${C_OK}✓${C_RST} %-32s %s\n" "$1" "$2"; }
    fail() { printf "  ${C_FAIL}✗${C_RST} %-32s %s\n" "$1" "$2"; FAILED=1; }
    warn() { printf "  ${C_WARN}⚠${C_RST} %-32s %s\n" "$1" "$2"; }
    hint() { printf "    ${C_DIM}→ %s${C_RST}\n" "$1"; }

    echo "Wellness Coach — Activity Monitor Diagnostic"
    echo "============================================"
    echo
    echo "Configuration"

    FORGE_CONF="$HOME/.claude/forge.conf"
    if [ -f "$FORGE_CONF" ]; then
        pass "forge.conf:" "$FORGE_CONF"
    else
        fail "forge.conf:" "missing"
        hint "Forge isn't installed yet. Run install.sh from the forge repo."
        echo; echo "Cannot continue diagnostic without forge.conf."
        exit 1
    fi

    VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
    if [ -n "$VAULT_PATH" ] && [ -d "$VAULT_PATH" ]; then
        pass "Vault path:" "$VAULT_PATH"
    else
        fail "Vault path:" "${VAULT_PATH:-not set} (not a directory)"
        hint "Check VAULT_PATH in $FORGE_CONF"
        echo; echo "Cannot continue without a valid vault path."
        exit 1
    fi

    PREFS="$VAULT_PATH/_shared/wellness-preferences.json"
    RUNTIME="$VAULT_PATH/_shared/wellness-runtime.json"
    if [ -f "$PREFS" ]; then
        pass "Preferences file:" "$PREFS"
    else
        fail "Preferences file:" "missing"
        hint "Wellness onboarding hasn't run. Invoke the wellness-coach skill in Claude."
        echo; echo "Cannot continue diagnostic without preferences."
        exit 1
    fi

    echo
    echo "Tier 2 flags (in $PREFS)"
    AM_INSTALLED=$(jq -r '.activity_monitor_installed // false' "$PREFS" 2>/dev/null)
    AM_ENABLED=$(jq -r '.activity_monitor_enabled // false' "$PREFS" 2>/dev/null)

    if [ "$AM_INSTALLED" = "true" ]; then
        pass "activity_monitor_installed:" "true"
    else
        warn "activity_monitor_installed:" "false"
        hint "Run install-monitor.sh to install the Tier 2 daemon."
    fi

    if [ "$AM_ENABLED" = "true" ]; then
        pass "activity_monitor_enabled:" "true"
    else
        fail "activity_monitor_enabled:" "false"
        hint "The hook ignores the idle log when this flag is false."
        hint "Fix: jq '.activity_monitor_enabled = true' $PREFS > $PREFS.tmp && mv $PREFS.tmp $PREFS"
        hint "Or re-run: ~/.claude/skills/wellness-coach/scripts/install-monitor.sh"
    fi

    echo
    echo "Binary"
    BINARY="$HOME/.claude/bin/screen_state"
    if [ -x "$BINARY" ]; then
        pass "screen_state binary:" "$BINARY"
        if OUT=$("$BINARY" 2>/dev/null); then
            pass "Binary executes:" "$OUT"
        else
            fail "Binary executes:" "non-zero exit"
            hint "Recompile: ~/.claude/skills/wellness-coach/scripts/install-monitor.sh"
        fi
    else
        fail "screen_state binary:" "missing or not executable at $BINARY"
        hint "Run install-monitor.sh to compile it."
    fi

    echo
    echo "Sampler"
    SAMPLER="$HOME/.claude/bin/idle-sampler.py"
    if [ -x "$SAMPLER" ]; then
        pass "idle-sampler.py:" "$SAMPLER"
    else
        fail "idle-sampler.py:" "missing or not executable at $SAMPLER"
        hint "Run install-monitor.sh to install it."
    fi

    PLIST_LABEL="com.claude.wellness-idle-sampler"
    PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
    if [ -f "$PLIST_PATH" ]; then
        pass "launchd plist:" "$PLIST_PATH"
    else
        fail "launchd plist:" "missing at $PLIST_PATH"
        hint "Run install-monitor.sh to install the LaunchAgent."
    fi

    if launchctl print "gui/$(id -u)/${PLIST_LABEL}" >/dev/null 2>&1; then
        pass "launchd job loaded:" "$PLIST_LABEL"
    else
        fail "launchd job loaded:" "not running"
        hint "Bootstrap: launchctl bootstrap gui/\$(id -u) $PLIST_PATH"
        hint "Or re-run: ~/.claude/skills/wellness-coach/scripts/install-monitor.sh"
    fi

    echo
    echo "Idle log"
    IDLE_LOG="$HOME/.claude/wellness-idle-log.json"
    if [ -f "$IDLE_LOG" ]; then
        pass "Idle log:" "$IDLE_LOG"
        # Newest sample timestamp (jq picks max .t from the array)
        NEWEST=$(jq -r 'map(.t // 0) | max // 0' "$IDLE_LOG" 2>/dev/null)
        if [ -n "$NEWEST" ] && [ "$NEWEST" != "0" ]; then
            NOW=$(date +%s)
            # NEWEST is a float; strip the fractional part for arithmetic.
            NEWEST_INT=${NEWEST%.*}
            AGE=$(( NOW - NEWEST_INT ))
            if [ "$AGE" -lt 120 ]; then
                pass "Last sample:" "${AGE}s ago (fresh)"
            elif [ "$AGE" -lt 7200 ]; then
                warn "Last sample:" "${AGE}s ago (within 2h cutoff, but sampler may be lagging)"
            else
                fail "Last sample:" "${AGE}s ago (stale — exceeds 2h cutoff, hook will ignore)"
                hint "Check launchd: launchctl print gui/\$(id -u)/${PLIST_LABEL}"
                hint "Check log: tail ~/.claude/wellness-idle-sampler.log"
            fi
        else
            fail "Last sample:" "log empty or unreadable"
            hint "Wait 60s for the sampler to fire, then re-run --diagnose."
        fi
        COUNT=$(jq -r 'length' "$IDLE_LOG" 2>/dev/null || echo "?")
        pass "Sample count (2h):" "$COUNT"
    else
        fail "Idle log:" "missing at $IDLE_LOG"
        hint "The sampler hasn't fired yet. Wait 60s after install, then re-check."
    fi

    echo
    if [ "$FAILED" -eq 0 ]; then
        printf "${C_OK}All Tier 2 components healthy.${C_RST}\n"
        exit 0
    else
        printf "${C_FAIL}One or more components need attention. See hints above.${C_RST}\n"
        exit 1
    fi
fi

# ----- statusline chip mode (default) ---------------------------------------

# Resolve vault path from forge.conf (same pattern as statusline.sh forge integration)
FORGE_CONF="$HOME/.claude/forge.conf"
[ -f "$FORGE_CONF" ] || exit 0

VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
[ -n "$VAULT_PATH" ] || exit 0

PREFS="$VAULT_PATH/_shared/wellness-preferences.json"
RUNTIME="$VAULT_PATH/_shared/wellness-runtime.json"
[ -f "$PREFS" ] || exit 0

# Read all needed fields. Prefs fields (intervals) come from PREFS; runtime
# fields (timestamps, strike_active) come from RUNTIME if present, else fall
# back to PREFS (handles pre-split installs where everything was in one file).
read_data=$(jq -r --slurpfile rt_arr <(jq '.' "$RUNTIME" 2>/dev/null || echo '{}') '
  ($rt_arr[0] // {}) as $rt |
  [
    ($rt.last_micro_break_timestamp // .last_micro_break_timestamp // ""),
    ($rt.last_break_timestamp // .last_break_timestamp // ""),
    (.micro_break_interval_minutes // 0),
    (.real_break_interval_minutes // 0),
    ($rt.strike_active // .strike_active // false)
  ] | @tsv
' "$PREFS" 2>/dev/null) || exit 0

[ -n "$read_data" ] || exit 0

IFS=$'\t' read -r LAST_MICRO LAST_BREAK MICRO_INT BREAK_INT STRIKE <<< "$read_data"

# Strike state — replaces both chips with a red warning
if [ "$STRIKE" = "true" ]; then
  printf "\033[31m⚠️ on strike\033[0m"
  exit 0
fi

# Need both timestamps + intervals to render meaningful chips
if [ -z "$LAST_MICRO" ] || [ -z "$LAST_BREAK" ] || [ "$MICRO_INT" -eq 0 ] || [ "$BREAK_INT" -eq 0 ]; then
  exit 0
fi

# Compute minutes to next stretch and break — macOS date syntax
NOW_EPOCH=$(date +%s)
MICRO_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$LAST_MICRO" +%s 2>/dev/null) || exit 0
BREAK_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$LAST_BREAK" +%s 2>/dev/null) || exit 0

MICRO_NEXT_MIN=$(( (MICRO_EPOCH + MICRO_INT * 60 - NOW_EPOCH) / 60 ))
BREAK_NEXT_MIN=$(( (BREAK_EPOCH + BREAK_INT * 60 - NOW_EPOCH) / 60 ))

# Format each chip — 🙆 clamps to 0m (no overdue concept since there's no compliance signal),
# ☕ shows "due" since the break timestamp reflects an actual user action.
if [ "$MICRO_NEXT_MIN" -lt 0 ]; then
  MICRO_CHIP="🙆 0m"
else
  MICRO_CHIP="🙆 ${MICRO_NEXT_MIN}m"
fi

if [ "$BREAK_NEXT_MIN" -le 0 ]; then
  BREAK_CHIP="☕ due"
else
  BREAK_CHIP="☕ ${BREAK_NEXT_MIN}m"
fi

# Color driven by ☕ only (the real compliance signal): red if due, yellow if ≤ 5min, green otherwise.
if [ "$BREAK_NEXT_MIN" -le 0 ]; then
  COLOR="\033[31m"
elif [ "$BREAK_NEXT_MIN" -le 5 ]; then
  COLOR="\033[33m"
else
  COLOR="\033[32m"
fi

printf "${COLOR}%s  %s\033[0m" "$MICRO_CHIP" "$BREAK_CHIP"
