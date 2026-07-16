#!/usr/bin/env python3
"""
Idle sampler for wellness-coach Forge module (Tier 2).
Runs via launchd every 60 seconds. Checks screen state and writes to idle log.

The log is a JSON array of samples, pruned to the last 2 hours.
Each sample: {"t": <unix_timestamp>, "display": "on"|"off", "locked": true|false}

Marker-gated since 2026-06-05: the script reads the forge-active marker on
every tick and no-ops when no Forge session is active. Aligns with the user
principle "Forge should not behave as if it monitors when not running" —
the launchd timer still wakes the script, but no samples land in the log
between sessions. See tasks/resolved/2026-06-04-idle-sampler-daemon-gating.md
"""
import json
import subprocess
import sys
import time
from pathlib import Path

LOG_PATH = Path.home() / ".claude" / "wellness-idle-log.json"
BINARY_PATH = Path.home() / ".claude" / "bin" / "screen_state"
FORGE_CONF_PATH = Path.home() / ".claude" / "forge.conf"
MAX_AGE_SECONDS = 7200  # 2 hours


def get_vault_path():
    """Read VAULT_PATH from ~/.claude/forge.conf. Returns None when absent
    or unreadable — caller treats that as 'Forge not configured, don't sample'.
    """
    if not FORGE_CONF_PATH.is_file():
        return None
    try:
        for line in FORGE_CONF_PATH.read_text().splitlines():
            if line.startswith("VAULT_PATH="):
                value = line.split("=", 1)[1].strip()
                return Path(value) if value else None
    except (OSError, ValueError):
        return None
    return None


def is_wellness_enabled():
    """True iff WELLNESS_ENABLED is exactly "true" in forge.conf.

    Strict — mirrors wellness-reset.sh and preferences.is_wellness_enabled():
    absent key / missing file => disabled. When the coach is off there's no
    consumer for the idle log, so don't sample. (This module is standalone —
    scripts/ can't import the hooks/ preferences module cleanly — so the read
    is duplicated here; keep the semantics identical.)
    """
    if not FORGE_CONF_PATH.is_file():
        return False
    try:
        for line in FORGE_CONF_PATH.read_text().splitlines():
            if line.strip().startswith("WELLNESS_ENABLED="):
                return line.split("=", 1)[1].strip() == "true"
    except OSError:
        return False
    return False


def is_forge_active():
    """True iff $VAULT_PATH/_shared/forge-active indicates an active session.

    Mirrors the marker-state convention from forge/SKILL.md step 1c:
      missing/empty/whitespace    -> not active
      literal '__pending__'        -> not active (launching, no project chosen)
      valid JSON with session_id   -> ACTIVE
      legacy plain-string project  -> ACTIVE (backward-compat)
      malformed JSON / unreadable  -> not active (defensive — don't sample on
                                     uncertainty; better to lose a tick than
                                     silently re-enable sampling against the
                                     user's intent)
    """
    vault = get_vault_path()
    if vault is None:
        return False
    marker = vault / "_shared" / "forge-active"
    if not marker.is_file():
        return False
    try:
        content = marker.read_text().strip()
    except OSError:
        return False
    if not content or content == "__pending__":
        return False
    # Try JSON first (canonical post-2026-04 format). If it looks like JSON
    # (starts with `{`) but doesn't parse, treat as malformed -> no-op, NOT
    # as legacy plain-string. Otherwise a half-written marker would silently
    # re-enable sampling.
    if content.lstrip().startswith("{"):
        try:
            data = json.loads(content)
            return isinstance(data, dict) and "session_id" in data
        except json.JSONDecodeError:
            return False
    # Legacy plain-string marker (pre-JSON migration): any non-empty,
    # non-pending content is active.
    return True


def get_screen_state():
    """Run the screen_state binary and parse output."""
    if not BINARY_PATH.exists():
        print(f"screen_state binary not found at {BINARY_PATH}", file=sys.stderr)
        return None
    try:
        out = subprocess.check_output(
            [str(BINARY_PATH)], text=True, timeout=5
        ).strip()
        # Parse "display=on,locked=0"
        parts = dict(p.split("=") for p in out.split(","))
        return {
            "display": parts.get("display", "on"),
            "locked": parts.get("locked", "0") == "1"
        }
    except subprocess.CalledProcessError as e:
        print(f"screen_state binary exited with code {e.returncode}", file=sys.stderr)
        return None
    except subprocess.TimeoutExpired:
        print("screen_state binary timed out", file=sys.stderr)
        return None
    except (ValueError, KeyError) as e:
        print(f"Could not parse screen_state output: {e}", file=sys.stderr)
        return None


def main():
    # Wellness-disabled gate: WELLNESS_ENABLED in forge.conf is the single
    # source of truth. When the coach is off, don't sample — nothing consumes
    # the idle log. Checked before the marker + screen_state subprocess.
    if not is_wellness_enabled():
        return

    # Marker gate (2026-06-05): no-op when no Forge session is active.
    # Saves the screen_state subprocess call too — gate runs first.
    if not is_forge_active():
        return

    state = get_screen_state()
    if state is None:
        return

    now = time.time()

    # Read existing log
    samples = []
    if LOG_PATH.exists():
        try:
            data = json.loads(LOG_PATH.read_text())
            if isinstance(data, list):
                samples = data
            else:
                print(f"Idle log is not a JSON array, resetting", file=sys.stderr)
        except json.JSONDecodeError as e:
            # Back up corrupt log for diagnostics
            corrupt_path = LOG_PATH.with_suffix(f".corrupt.{int(now)}")
            try:
                LOG_PATH.rename(corrupt_path)
                print(f"Idle log corrupt ({e}), backed up to {corrupt_path.name}",
                      file=sys.stderr)
            except OSError:
                print(f"Idle log corrupt ({e}), could not back up", file=sys.stderr)
        except IOError as e:
            print(f"Could not read idle log: {e}", file=sys.stderr)

    # Append new sample
    samples.append({
        "t": now,
        "display": state["display"],
        "locked": state["locked"]
    })

    # Prune old samples
    cutoff = now - MAX_AGE_SECONDS
    samples = [s for s in samples if isinstance(s, dict) and s.get("t", 0) > cutoff]

    # Write atomically
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = LOG_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(samples))
    tmp.replace(LOG_PATH)


if __name__ == "__main__":
    main()
