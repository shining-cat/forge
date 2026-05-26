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

    # Show active thresholds (defaults: 5 / 15 — per preferences.py).
    # Helpful when debugging why a particular lock did or didn't get credited.
    MICRO_T=$(jq -r '.micro_break_lock_threshold_minutes // 5' "$PREFS" 2>/dev/null)
    REAL_T=$(jq -r '.real_break_lock_threshold_minutes // 15' "$PREFS" 2>/dev/null)
    pass "Lock thresholds:" "< ${MICRO_T}min ignore | ${MICRO_T}–${REAL_T}min micro | ≥ ${REAL_T}min real"

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

# ----- state mode (canonical runtime dump) ----------------------------------
#
# Print all runtime + setup values that determine current wellness behaviour,
# in one human-readable view. Built specifically to short-circuit the
# triangulation-across-files debugging pattern that recurs whenever something
# seems off with break crediting (see task
# 2026-05-26-wellness-runtime-state-observability).
#
# Canonical sources:
#   - wellness-preferences.json  — setup keys (tracked)
#   - wellness-runtime.json      — runtime keys (gitignored, auto-modified)
# See preferences.py:55-70 for the split. read_prefs() merges both transparently.

if [ "${1:-}" = "--state" ]; then
    FORGE_CONF="$HOME/.claude/forge.conf"
    if [ ! -f "$FORGE_CONF" ]; then
        echo "forge.conf missing at $FORGE_CONF — wellness coach not installed via Forge." >&2
        exit 1
    fi
    VAULT_PATH=$(grep '^VAULT_PATH=' "$FORGE_CONF" | cut -d= -f2-)
    if [ -z "$VAULT_PATH" ] || [ ! -d "$VAULT_PATH" ]; then
        echo "VAULT_PATH unset or not a directory: ${VAULT_PATH:-<unset>}" >&2
        exit 1
    fi

    PREFS="$VAULT_PATH/_shared/wellness-preferences.json"
    RUNTIME="$VAULT_PATH/_shared/wellness-runtime.json"
    ACTIVITY_LOG="$HOME/.claude/wellness-activity-log.md"

    if [ ! -f "$PREFS" ]; then
        echo "Preferences file missing: $PREFS" >&2
        echo "Wellness onboarding hasn't run." >&2
        exit 1
    fi

    NOW_EPOCH=$(date +%s)
    NOW_ISO=$(date +"%Y-%m-%dT%H:%M %Z")

    # Helper: format "(N min ago)" or "(N min from now)" for an ISO timestamp.
    age_str() {
        local iso="$1"
        [ -z "$iso" ] || [ "$iso" = "null" ] && { echo ""; return; }
        local t
        t=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$iso" +%s 2>/dev/null) || { echo "(unparseable)"; return; }
        local delta=$(( NOW_EPOCH - t ))
        if [ "$delta" -ge 0 ]; then
            echo "($(( delta / 60 )) min ago)"
        else
            echo "($(( -delta / 60 )) min from now)"
        fi
    }

    # Read prefs
    PERSONA=$(jq -r '.persona // "(unset)"' "$PREFS")
    COACH=$(jq -r '.coach_name // "(unset)"' "$PREFS")
    MICRO_INT=$(jq -r '.micro_break_interval_minutes // 0' "$PREFS")
    REAL_INT=$(jq -r '.real_break_interval_minutes // 0' "$PREFS")
    INSIST=$(jq -r '.insistence_level // "(unset)"' "$PREFS")
    STRIKE_DELAY=$(jq -r '.strike_delay_minutes // 0' "$PREFS")
    MAX_SNOOZE=$(jq -r '.max_snoozes // 0' "$PREFS")
    CAL_EN=$(jq -r '.calendar_enabled // false' "$PREFS")
    WX_EN=$(jq -r '.weather_enabled // false' "$PREFS")
    WX_CITY=$(jq -r '.weather_city // ""' "$PREFS")
    AM_EN=$(jq -r '.activity_monitor_enabled // false' "$PREFS")
    AM_INST=$(jq -r '.activity_monitor_installed // false' "$PREFS")
    MICRO_T=$(jq -r '.micro_break_lock_threshold_minutes // 5' "$PREFS")
    REAL_T=$(jq -r '.real_break_lock_threshold_minutes // 15' "$PREFS")
    EOD=$(jq -r '.preferred_end_of_day // "(unset)"' "$PREFS")

    # Read runtime (may not exist on fresh install)
    if [ -f "$RUNTIME" ]; then
        LAST_BREAK=$(jq -r '.last_break_timestamp // ""' "$RUNTIME")
        LAST_MICRO=$(jq -r '.last_micro_break_timestamp // ""' "$RUNTIME")
        LAST_REMIND=$(jq -r '.last_reminder_timestamp // ""' "$RUNTIME")
        STRIKE_ACTIVE=$(jq -r '.strike_active // false' "$RUNTIME")
        STRIKE_CLEARED=$(jq -r '.strike_cleared_at // ""' "$RUNTIME")
        SNOOZE_COUNT=$(jq -r '.snooze_count // 0' "$RUNTIME")
        HIST_COUNT=$(jq -r '.break_history // [] | length' "$RUNTIME")
    else
        LAST_BREAK=""; LAST_MICRO=""; LAST_REMIND=""
        STRIKE_ACTIVE="false"; STRIKE_CLEARED=""; SNOOZE_COUNT=0; HIST_COUNT=0
    fi

    # ---- Header
    echo "Wellness state — ${COACH} (${NOW_ISO})"
    echo "================================================================"

    # ---- Setup
    echo
    echo "Setup"
    printf "  %-22s : %s\n" "Persona" "${PERSONA} (${COACH})"
    printf "  %-22s : %s min\n" "Micro interval" "${MICRO_INT}"
    printf "  %-22s : %s min\n" "Real interval" "${REAL_INT}"
    printf "  %-22s : %s\n" "Insistence" "${INSIST}"
    printf "  %-22s : %s min\n" "Strike delay" "${STRIKE_DELAY}"
    printf "  %-22s : %s\n" "Max snoozes" "${MAX_SNOOZE}"
    printf "  %-22s : %s\n" "Calendar enabled" "${CAL_EN}"
    if [ "$WX_EN" = "true" ] && [ -n "$WX_CITY" ]; then
        printf "  %-22s : %s (%s)\n" "Weather enabled" "${WX_EN}" "${WX_CITY}"
    else
        printf "  %-22s : %s\n" "Weather enabled" "${WX_EN}"
    fi
    printf "  %-22s : enabled=%s installed=%s\n" "Activity monitor" "${AM_EN}" "${AM_INST}"
    printf "  %-22s : <%sm ignore | %s–%sm micro | ≥%sm real\n" "Lock thresholds" "${MICRO_T}" "${MICRO_T}" "${REAL_T}" "${REAL_T}"
    printf "  %-22s : %s\n" "Preferred end-of-day" "${EOD}"

    # ---- Runtime
    echo
    echo "Runtime"
    printf "  %-22s : %s %s\n" "last_break" "${LAST_BREAK:-(unset)}" "$(age_str "$LAST_BREAK")"
    printf "  %-22s : %s %s\n" "last_micro_break" "${LAST_MICRO:-(unset)}" "$(age_str "$LAST_MICRO")"
    printf "  %-22s : %s %s\n" "last_reminder" "${LAST_REMIND:-(unset)}" "$(age_str "$LAST_REMIND")"
    printf "  %-22s : %s\n" "strike_active" "${STRIKE_ACTIVE}"
    printf "  %-22s : %s\n" "strike_cleared_at" "${STRIKE_CLEARED:-(none)}"
    printf "  %-22s : %s\n" "snooze_count" "${SNOOZE_COUNT}"
    printf "  %-22s : %s entries\n" "break_history" "${HIST_COUNT}"

    # ---- Next scheduled (only computable if runtime + intervals present)
    echo
    echo "Next scheduled"
    if [ -n "$LAST_MICRO" ] && [ "$MICRO_INT" -gt 0 ]; then
        MICRO_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$LAST_MICRO" +%s 2>/dev/null)
        if [ -n "$MICRO_EPOCH" ]; then
            MICRO_NEXT_EPOCH=$(( MICRO_EPOCH + MICRO_INT * 60 ))
            MICRO_NEXT_ISO=$(date -j -f "%s" "$MICRO_NEXT_EPOCH" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)
            MICRO_DELTA=$(( MICRO_NEXT_EPOCH - NOW_EPOCH ))
            if [ "$MICRO_DELTA" -le 0 ]; then
                printf "  %-22s : %s (%d min ago — DUE)\n" "micro nag at" "${MICRO_NEXT_ISO}" "$(( -MICRO_DELTA / 60 ))"
            else
                printf "  %-22s : %s (in %d min)\n" "micro nag at" "${MICRO_NEXT_ISO}" "$(( MICRO_DELTA / 60 ))"
            fi
        fi
    else
        printf "  %-22s : (insufficient state)\n" "micro nag at"
    fi
    if [ -n "$LAST_BREAK" ] && [ "$REAL_INT" -gt 0 ]; then
        BREAK_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$LAST_BREAK" +%s 2>/dev/null)
        if [ -n "$BREAK_EPOCH" ]; then
            REAL_NEXT_EPOCH=$(( BREAK_EPOCH + REAL_INT * 60 ))
            REAL_NEXT_ISO=$(date -j -f "%s" "$REAL_NEXT_EPOCH" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)
            REAL_DELTA=$(( REAL_NEXT_EPOCH - NOW_EPOCH ))
            if [ "$REAL_DELTA" -le 0 ]; then
                printf "  %-22s : %s (%d min ago — DUE)\n" "real nag at" "${REAL_NEXT_ISO}" "$(( -REAL_DELTA / 60 ))"
            else
                printf "  %-22s : %s (in %d min)\n" "real nag at" "${REAL_NEXT_ISO}" "$(( REAL_DELTA / 60 ))"
            fi
        fi
    else
        printf "  %-22s : (insufficient state)\n" "real nag at"
    fi

    # ---- Recent break history (last 5)
    echo
    echo "Recent break history (last 5)"
    if [ -f "$RUNTIME" ] && [ "$HIST_COUNT" -gt 0 ]; then
        jq -r '.break_history // [] | .[-5:] | reverse | .[] | "  \(.timestamp)  \(.type)"' "$RUNTIME"
    else
        echo "  (none)"
    fi

    # ---- Files
    echo
    echo "Files"
    printf "  %-13s : %s\n" "Prefs" "$PREFS"
    printf "  %-13s : %s\n" "Runtime" "$RUNTIME"
    printf "  %-13s : %s\n" "Activity log" "$ACTIVITY_LOG"

    exit 0
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
