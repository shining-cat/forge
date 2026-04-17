#!/usr/bin/env python3
"""
Idle sampler for wellness-coach plugin (Tier 2).
Runs via launchd every 60 seconds. Checks screen state and writes to idle log.

The log is a JSON array of samples, pruned to the last 2 hours.
Each sample: {"t": <unix_timestamp>, "display": "on"|"off", "locked": true|false}
"""
import json
import subprocess
import sys
import time
from pathlib import Path

LOG_PATH = Path.home() / ".claude" / "wellness-idle-log.json"
BINARY_PATH = Path.home() / ".claude" / "bin" / "screen_state"
MAX_AGE_SECONDS = 7200  # 2 hours


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
