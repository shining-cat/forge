#!/usr/bin/env python3
"""
Shared preferences module for wellness-coach Forge module.
Reads/writes wellness-preferences.json (path resolved via forge.conf — see _resolve_prefs_path).
"""
import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

def _resolve_shared_dir() -> Path:
    """Resolve the vault's _shared/ directory (or legacy ~/.claude/ fallback).

    Reads VAULT_PATH from ~/.claude/forge.conf and returns {VAULT_PATH}/_shared.
    Falls back to ~/.claude/ (with a stderr warning) if forge.conf is missing or
    VAULT_PATH is unset, so the wellness-coach module remains usable standalone.
    """
    legacy = Path.home() / ".claude"
    forge_conf = Path.home() / ".claude" / "forge.conf"
    if not forge_conf.is_file():
        print(
            "[wellness-coach] forge.conf not found — using legacy path "
            f"{legacy}/wellness-preferences.json (install Forge to silence prompts).",
            file=sys.stderr,
        )
        return legacy
    vault_path = ""
    try:
        for raw in forge_conf.read_text().splitlines():
            line = raw.strip()
            if line.startswith("VAULT_PATH="):
                vault_path = line.split("=", 1)[1].strip()
                break
    except OSError as e:
        print(
            f"[wellness-coach] Could not read forge.conf ({e}) — using legacy path {legacy}.",
            file=sys.stderr,
        )
        return legacy
    if not vault_path:
        print(
            "[wellness-coach] VAULT_PATH not set in forge.conf — using legacy "
            f"path {legacy}.",
            file=sys.stderr,
        )
        return legacy
    return Path(vault_path) / "_shared"


def _read_forge_conf_value(key, conf_path=None):
    """Read a single ``KEY=value`` line from forge.conf.

    Returns the stripped value string, or None when the file is missing/
    unreadable or the key is absent. ``conf_path`` is overridable for tests.
    """
    conf_path = Path(conf_path) if conf_path else Path.home() / ".claude" / "forge.conf"
    if not conf_path.is_file():
        return None
    try:
        for raw in conf_path.read_text().splitlines():
            line = raw.strip()
            if line.startswith(f"{key}="):
                return line.split("=", 1)[1].strip()
    except OSError:
        return None
    return None


def is_wellness_enabled(conf_path=None):
    """True iff ``WELLNESS_ENABLED`` is exactly ``"true"`` in forge.conf.

    Strict, matching wellness-reset.sh's ``[ "$WELLNESS_ENABLED" = "true" ]``
    gate: any other value — ``false``, empty, an absent key, or a missing
    forge.conf — reads as disabled. This makes the flag the single source of
    truth for the whole enforcement path (PreToolUse strike/break, the Stop
    tick, the precompact suggestion, the idle sampler); when disabled, none of
    them fire. The absent-key-means-disabled choice is deliberate (aligned with
    wellness-reset.sh) — a config without the key does not silently enforce.
    """
    return _read_forge_conf_value("WELLNESS_ENABLED", conf_path) == "true"


_SHARED_DIR = _resolve_shared_dir()
PREFS_PATH = _SHARED_DIR / "wellness-preferences.json"
RUNTIME_PATH = _SHARED_DIR / "wellness-runtime.json"

# Fields that live in wellness-runtime.json (auto-modified by the coach during
# normal operation — gitignored to keep vault commits signal-only). Everything
# else stays in wellness-preferences.json (tracked).
RUNTIME_FIELDS = frozenset({
    "last_break_timestamp",
    "last_micro_break_timestamp",
    "last_reminder_timestamp",
    "strike_active",
    "strike_cleared_at",
    "snooze_count",
    "break_history",
    "resistance_pattern",
})

DEFAULT_PREFS = {
    "persona": "playful",
    "interruption_level": "escalating_strike",
    "break_interval_minutes": 60,
    "micro_break_interval_minutes": 25,
    "max_snoozes": 1,
    "strike_delay_minutes": 15,
    "calendar_enabled": False,
    "weather_enabled": False,
    "weather_location": None,
    "min_outdoor_temp_c": None,
    "personal_notes": [],
    "energy_patterns": {},
    "last_break_timestamp": None,
    "last_micro_break_timestamp": None,
    "last_reminder_timestamp": None,
    "strike_active": False,
    "snooze_count": 0,
    "break_history": [],
    "resistance_pattern": None,
    "activity_monitor_enabled": False,
    "activity_monitor_installed": False,
    # Tiered lock-duration thresholds (auto-detected breaks only — explicit
    # acks are always credited as real regardless of duration).
    # Locks < micro threshold are ignored entirely (noise floor).
    # Locks ≥ micro and < real are credited as micro (resets 🙆 timer only,
    # does NOT clear strike, logs as "auto-micro").
    # Locks ≥ real are credited as real (resets both timers, clears strike,
    # logs as "auto-real").
    #
    # 5min micro = stretch / restroom / drink water (a genuine reset, not
    # a screensaver flash). 15min real = left the desk (long enough that
    # the user physically moved away, not just looked away).
    "micro_break_lock_threshold_minutes": 5,
    "real_break_lock_threshold_minutes": 15
}

IDLE_LOG_PATH = Path.home() / ".claude" / "wellness-idle-log.json"
IDLE_LOG_MAX_AGE_MINUTES = 120  # log is stale if no sample in this window

# Defaults for tiered lock-duration detection. User-configurable via the
# matching prefs keys above. See DEFAULT_PREFS comment for the tier semantics.
MICRO_BREAK_LOCK_THRESHOLD_MINUTES = 5
REAL_BREAK_LOCK_THRESHOLD_MINUTES = 15


def read_prefs():
    """Read merged view of preferences + runtime state.

    Combines wellness-preferences.json (tracked) and wellness-runtime.json (gitignored)
    into a single dict for callers — the split is invisible above this layer.
    Returns None if the prefs file doesn't exist (onboarding needed).
    Missing/corrupt runtime file degrades gracefully (no fields from it).
    """
    if not PREFS_PATH.exists():
        return None
    try:
        with open(PREFS_PATH, "r") as f:
            merged = json.load(f)
    except json.JSONDecodeError as e:
        print(f"WARNING: wellness preferences file is corrupt: {e}", file=sys.stderr)
        print(f"  Path: {PREFS_PATH}", file=sys.stderr)
        print(f"  Fix: delete the file and re-onboard, or repair the JSON.", file=sys.stderr)
        return None
    except IOError as e:
        print(f"WARNING: cannot read wellness preferences: {e}", file=sys.stderr)
        return None
    # Merge runtime fields if the runtime file exists. Runtime values override
    # any matching keys in prefs (handles the migration window where a field
    # still exists in both files — runtime is authoritative for runtime fields).
    if RUNTIME_PATH.exists():
        try:
            with open(RUNTIME_PATH, "r") as f:
                runtime = json.load(f)
            if isinstance(runtime, dict):
                merged.update(runtime)
        except (json.JSONDecodeError, IOError):
            pass  # silent — missing/corrupt runtime is non-fatal
    return merged


def _atomic_write_json(path: Path, data: dict) -> None:
    """Write JSON to path atomically (temp file + rename)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(".tmp")
    try:
        with open(tmp_path, "w") as f:
            json.dump(data, f, indent=2)
    except (IOError, TypeError, ValueError):
        tmp_path.unlink(missing_ok=True)
        raise
    tmp_path.replace(path)


def write_prefs(combined):
    """Write the merged dict, splitting prefs vs runtime fields into the two files.

    Both files are written atomically (temp + rename). The runtime file is only
    written if at least one runtime field is present — keeps it absent for
    onboarding-only states where no runtime data exists yet.
    """
    runtime_data = {k: combined[k] for k in RUNTIME_FIELDS if k in combined}
    prefs_data = {k: v for k, v in combined.items() if k not in RUNTIME_FIELDS}
    _atomic_write_json(PREFS_PATH, prefs_data)
    if runtime_data:
        _atomic_write_json(RUNTIME_PATH, runtime_data)


def minutes_since(timestamp_str):
    """Calculate minutes elapsed since an ISO timestamp string.
    Handles both naive (no timezone) and aware (+00:00, Z) formats."""
    if not timestamp_str:
        return float("inf")
    try:
        # Strip timezone suffix for consistent parsing
        clean = timestamp_str.replace("Z", "").replace("+00:00", "")
        # Handle microseconds if present
        if "." in clean:
            clean = clean[:clean.index(".")]
        ts = time.mktime(time.strptime(clean, "%Y-%m-%dT%H:%M:%S"))
        return (time.time() - ts) / 60.0
    except (ValueError, TypeError):
        return float("inf")


def _lock_timeout_handler(signum, frame):
    raise TimeoutError("Lock acquisition timed out")


def read_modify_write(modifier_fn):
    """Read prefs, apply modifier, write back — with file lock for multi-terminal safety.
    Lock acquisition times out after 3 seconds to prevent deadlock."""
    PREFS_PATH.parent.mkdir(parents=True, exist_ok=True)
    lock_path = PREFS_PATH.with_suffix(".lock")
    with open(lock_path, "w") as lock_fd:
        try:
            old_handler = signal.signal(signal.SIGALRM, _lock_timeout_handler)
            signal.alarm(3)
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old_handler)
        except TimeoutError:
            print("WARNING: Could not acquire preferences lock within 3s. "
                  "Proceeding without lock.", file=sys.stderr)
        prefs = read_prefs() or dict(DEFAULT_PREFS)
        result = modifier_fn(prefs)
        if result is not None:
            write_prefs(result)
        return result


def read_idle_log():
    """Read idle log. Returns list of samples or empty list if unavailable/stale."""
    if not IDLE_LOG_PATH.exists():
        return []
    try:
        data = json.loads(IDLE_LOG_PATH.read_text())
        if not isinstance(data, list) or not data:
            return []
        # Validate structure: each sample needs "t", "display"
        samples = [s for s in data if isinstance(s, dict) and "t" in s and "display" in s]
        if not samples:
            return []
        # Check if log is stale (no recent sample)
        newest = max(s["t"] for s in samples)
        if (time.time() - newest) / 60.0 > IDLE_LOG_MAX_AGE_MINUTES:
            return []  # sampler not running
        return samples
    except (json.JSONDecodeError, IOError):
        return []


def find_last_screen_off_break(samples, micro_threshold_minutes=None,
                               real_threshold_minutes=None):
    """Find the last lock/off period and classify it into a tier.

    Returns a tuple (timestamp_iso, duration_minutes, tier) where tier is:
      "real"  — duration ≥ real_threshold
      "micro" — micro_threshold ≤ duration < real_threshold
    Returns None if no qualifying lock period is found (duration < micro
    threshold, or no off→on transition in the samples).

    The caller uses the tier to decide credit semantics:
      "real"  → resets both timers, clears strike, logs "auto-real"
      "micro" → resets 🙆 only, does NOT clear strike, logs "auto-micro"
    Sub-threshold locks return None and produce no log entry — they're noise
    (phone glance, someone walking by).
    """
    if micro_threshold_minutes is None:
        micro_threshold_minutes = MICRO_BREAK_LOCK_THRESHOLD_MINUTES
    if real_threshold_minutes is None:
        real_threshold_minutes = REAL_BREAK_LOCK_THRESHOLD_MINUTES
    if not samples:
        return None

    # Sort by timestamp
    samples = sorted(samples, key=lambda s: s["t"])

    # Walk backwards looking for on→off transitions
    for i in range(len(samples) - 1, 0, -1):
        curr = samples[i]
        prev = samples[i - 1]

        # Found return from break: screen was off/locked, now on and unlocked
        curr_away = curr["display"] == "off" or curr.get("locked")
        prev_away = prev["display"] == "off" or prev.get("locked")

        if not curr_away and prev_away:
            # Walk back to find break start
            j = i - 1
            while j >= 0:
                s = samples[j]
                if s["display"] == "on" and not s.get("locked"):
                    break
                j -= 1
            break_start = samples[j + 1]["t"] if j >= 0 else samples[0]["t"]
            break_end = curr["t"]
            duration_min = (break_end - break_start) / 60.0

            if duration_min >= real_threshold_minutes:
                tier = "real"
            elif duration_min >= micro_threshold_minutes:
                tier = "micro"
            else:
                return None  # below noise floor — ignore entirely

            ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(break_end))
            return (ts, duration_min, tier)

    return None


def _parse_sysctl_timestamp(key):
    """Parse a sysctl timestamp key (kern.waketime, kern.boottime).
    Returns epoch seconds (int) or None."""
    try:
        out = subprocess.check_output(
            ["sysctl", "-n", key], text=True, timeout=2
        ).strip()
        # Parse "{ sec = 1775801440, usec = 185792 } Fri Apr 10 08:10:40 2026"
        sec_start = out.index("sec = ") + 6
        sec_end = out.index(",", sec_start)
        return int(out[sec_start:sec_end])
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return None
    except (ValueError, IndexError):
        return None


def get_system_wake_time():
    """Get last system wake-from-sleep timestamp. Returns ISO string or None.
    Returns None after a fresh reboot (no sleep cycle yet — kern.waketime is 0)."""
    epoch = _parse_sysctl_timestamp("kern.waketime")
    if not epoch:  # None or 0 (fresh boot, no sleep/wake yet)
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(epoch))


def get_system_boot_time():
    """Get system boot timestamp. Returns ISO string or None."""
    epoch = _parse_sysctl_timestamp("kern.boottime")
    if not epoch:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(epoch))


SCREEN_STATE_BINARY = Path.home() / ".claude" / "bin" / "screen_state"


def get_current_screen_state():
    """Run screen_state binary and return {"display": ..., "locked": ...}, or None."""
    if not SCREEN_STATE_BINARY.exists():
        return None
    try:
        out = subprocess.check_output(
            [str(SCREEN_STATE_BINARY)], text=True, timeout=2
        ).strip()
        parts = dict(p.split("=") for p in out.split(","))
        return {
            "display": parts.get("display", "on"),
            "locked": parts.get("locked", "0") == "1",
        }
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            FileNotFoundError, ValueError, KeyError):
        return None


def now_iso():
    """Return current time as ISO string."""
    return time.strftime("%Y-%m-%dT%H:%M:%S")
