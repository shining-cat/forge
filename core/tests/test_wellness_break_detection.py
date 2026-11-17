#!/usr/bin/env python3
"""Hermetic completed-lock detection and credit regressions for both adapters."""
import importlib.util
import os
import sys
import tempfile
import time
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
NOW = 1_800_000_000


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(epoch))


class BreakDetectionCases:
    def setUp(self):
        stack = ExitStack()
        self.addCleanup(stack.close)
        root = Path(stack.enter_context(tempfile.TemporaryDirectory()))
        (root / "vault" / "_shared").mkdir(parents=True)
        conf = root / "forge.conf"
        conf.write_text(f"VAULT_PATH={root / 'vault'}\nWELLNESS_ENABLED=true\n")
        stack.enter_context(patch.dict(os.environ, {
            "HOME": str(root),
            "COPILOT_HOME": str(root),
            "CLAUDE_HOME": str(root),
            "FORGE_CONF_OVERRIDE": str(conf),
        }))
        hooks = ROOT / f"adapters/{self.adapter}/modules/wellness-coach/hooks"
        stack.enter_context(patch.object(sys, "path", [str(hooks), *sys.path]))
        stack.enter_context(patch.object(sys, "dont_write_bytecode", True))
        stack.enter_context(patch.dict(sys.modules))
        for module in hooks.glob("*.py"):
            sys.modules.pop(module.stem, None)
        spec = importlib.util.spec_from_file_location("timer_test", hooks / "wellness-timer.py")
        self.timer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.timer)

    def samples(self, duration, noise=True):
        end = NOW - 4 * 60
        start = end - duration * 60
        samples = [
            {"t": start - 60, "display": "on", "locked": False},
            {"t": start, "display": "off", "locked": True},
            {"t": end, "display": "on", "locked": False},
        ]
        if noise:
            samples.extend([
                {"t": NOW - 2 * 60, "display": "off", "locked": True},
                {"t": NOW, "display": "on", "locked": False},
            ])
        return samples

    def long_break_samples(self):
        samples = self.samples(66)
        start = samples[1]["t"]
        samples[2:2] = [
            {"t": start + 2 * 60, "display": "on", "locked": True},
            {"t": start + 3 * 60, "display": "off", "locked": True},
        ]
        return samples

    def test_long_break_survives_flicker_and_short_relock(self):
        result = self.timer.find_last_screen_off_break(self.long_break_samples())
        self.assertEqual(result, (iso(NOW - 4 * 60), 66, "real"))

    def test_noise_only_has_no_break(self):
        self.assertIsNone(self.timer.find_last_screen_off_break(self.samples(2)))

    def test_latest_qualifying_period_wins_not_longest(self):
        older = [{**s, "t": s["t"] - 10 * 60} for s in self.samples(66, noise=False)]
        result = self.timer.find_last_screen_off_break(older + self.samples(5))
        self.assertEqual(result, (iso(NOW - 4 * 60), 5, "micro"))

    def test_threshold_boundaries_behind_noise(self):
        for micro, real in ((5, 15), (3, 10)):
            for duration, tier in ((micro - 1, None), (micro, "micro"),
                                   (real - 1, "micro"), (real, "real")):
                with self.subTest(micro=micro, real=real, duration=duration):
                    result = self.timer.find_last_screen_off_break(
                        self.samples(duration),
                        micro_threshold_minutes=micro,
                        real_threshold_minutes=real,
                    )
                    expected = None if tier is None else (iso(NOW - 4 * 60), duration, tier)
                    self.assertEqual(result, expected)

    def check_credit_once(self, tier, samples, last_real):
        prefs = {
            "wellness_onboarding_complete": True,
            "activity_monitor_enabled": True,
            "last_break_timestamp": last_real,
            "last_micro_break_timestamp": last_real,
            "break_history": [],
            "calendar_enabled": False,
        }
        timer = self.timer
        credit = Mock(wraps=timer._credit_auto_break)
        with ExitStack() as stack:
            clock = stack.enter_context(patch.object(timer.time, "time", return_value=NOW))
            stack.enter_context(patch.multiple(
                timer,
                is_wellness_enabled=Mock(return_value=True),
                consented=Mock(return_value=True),
                read_prefs=Mock(return_value=prefs),
                read_hook_input=Mock(return_value={"hook_event_name": "Stop"}),
                read_idle_log=Mock(return_value=samples),
                read_modify_write=Mock(side_effect=lambda modifier: modifier(prefs)),
                now_iso=lambda: iso(clock.return_value),
                get_current_screen_state=Mock(return_value=None),
                get_system_wake_time=Mock(return_value=None),
                get_system_boot_time=Mock(return_value=None),
                try_reminder_lock=Mock(return_value=None),
                log_event=Mock(),
                notify=Mock(),
                get_context_lines=Mock(return_value=[]),
                _credit_auto_break=credit,
            ))
            self.assertEqual(timer._detect_auto_break(prefs), (iso(NOW - 4 * 60), tier))
            for tick in (NOW, NOW + 120):
                clock.return_value = tick
                with self.assertRaises(SystemExit) as stopped:
                    timer.main()
                self.assertEqual(stopped.exception.code, 0)
                self.assertEqual(credit.call_count, 1)
                self.assertEqual(prefs["last_micro_break_timestamp"], iso(NOW))
                expected_real = iso(NOW) if tier == "real" else last_real
                self.assertEqual(prefs["last_break_timestamp"], expected_real)
            self.assertEqual(credit.call_args.args[4], tier)
            self.assertEqual(len(prefs["break_history"]), 1 if tier == "real" else 0)

    def test_recovered_real_credits_once_through_main(self):
        self.check_credit_once("real", self.long_break_samples(), iso(NOW - 80 * 60))

    def test_recovered_micro_credits_once_without_resetting_real(self):
        self.check_credit_once("micro", self.samples(5), iso(NOW - 12 * 60))


class CopilotBreakDetectionTest(BreakDetectionCases, unittest.TestCase):
    adapter = "copilot-cli"


class ClaudeBreakDetectionTest(BreakDetectionCases, unittest.TestCase):
    adapter = "claude-code"


if __name__ == "__main__":
    unittest.main()
