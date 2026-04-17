#!/usr/bin/env python3
"""Context enrichment for wellness-coach break reminders (weather, calendar, energy)."""
import json
import os
import subprocess
import time
from datetime import datetime, timezone

from formatting import BOX_TEXT_WIDTH
from preferences import minutes_since, now_iso

SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")
CALENDAR_CACHE_PATH = os.path.expanduser("~/.claude/wellness-calendar-cache.json")
CALENDAR_CACHE_TTL_MINUTES = 15


def fetch_weather(city):
    """Fetch weather via weather.sh script. Returns dict or None."""
    script = os.path.join(SCRIPTS_DIR, "weather.sh")
    if not os.path.exists(script) or not city:
        return None
    try:
        result = subprocess.run(
            [script, city], capture_output=True, text=True, timeout=3
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip())
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        pass
    return None


def _read_stale_cache():
    """Read calendar cache regardless of age."""
    try:
        with open(CALENDAR_CACHE_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def fetch_or_read_calendar_cache():
    """Read calendar cache if fresh (< 15 min), fetch live if stale."""
    cache = _read_stale_cache()
    if cache and cache.get("fetched_at"):
        if minutes_since(cache["fetched_at"]) < CALENDAR_CACHE_TTL_MINUTES:
            return cache

    try:
        token = subprocess.run(
            ["gcloud", "auth", "application-default", "print-access-token"],
            capture_output=True, text=True, timeout=3
        ).stdout.strip()
        if not token:
            return cache

        project = subprocess.run(
            ["gcloud", "config", "get-value", "project"],
            capture_output=True, text=True, timeout=2
        ).stdout.strip()

        now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        eod_utc = datetime.now(timezone.utc).replace(
            hour=23, minute=59
        ).strftime("%Y-%m-%dT%H:%M:%SZ")

        url = (
            "https://www.googleapis.com/calendar/v3/calendars/primary/events"
            f"?maxResults=5&timeMin={now_utc}&timeMax={eod_utc}"
            "&orderBy=startTime&singleEvents=true"
        )
        result = subprocess.run(
            ["curl", "-sS",
             "-H", f"Authorization: Bearer {token}",
             "-H", f"x-goog-user-project: {project}",
             url],
            capture_output=True, text=True, timeout=4
        )
        if result.returncode != 0:
            return cache

        data = json.loads(result.stdout)
        events = data.get("items", [])
        next_event = None
        events_today = []
        for e in events:
            attendees = e.get("attendees", [])
            if attendees:
                me = next((a for a in attendees if a.get("self")), None)
                if me and me.get("responseStatus") == "declined":
                    continue
            start = e.get("start", {}).get(
                "dateTime", e.get("start", {}).get("date", "")
            )
            entry = {"summary": e.get("summary", "Meeting"), "start": start}
            events_today.append(entry)
            if not next_event:
                next_event = entry

        new_cache = {
            "fetched_at": now_iso(),
            "next_event": next_event,
            "events_today": events_today,
        }
        try:
            with open(CALENDAR_CACHE_PATH, "w") as f:
                json.dump(new_cache, f)
        except OSError:
            pass
        return new_cache

    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        return cache


def get_context_lines(prefs):
    """Assemble weather/calendar/energy context lines for real breaks."""
    lines = []

    # Weather
    if prefs.get("weather_enabled"):
        weather = fetch_weather(prefs.get("weather_city", ""))
        if weather:
            temp = weather.get("temp_c", "?")
            condition = weather.get("condition", "").lower()
            outdoor = weather.get("is_outdoor_friendly", False)
            min_temp = prefs.get("min_outdoor_temp_c", 5)
            if outdoor and isinstance(temp, (int, float)) and temp >= min_temp:
                lines.append(f"{temp}°C {condition} — go outside?")
            else:
                lines.append(f"{temp}°C {condition} — stretch indoors")

    # Calendar
    if prefs.get("calendar_enabled"):
        cal = fetch_or_read_calendar_cache()
        if cal and cal.get("next_event"):
            event = cal["next_event"]
            summary = event.get("summary", "Meeting")
            start_str = event.get("start", "")
            if start_str:
                try:
                    start_clean = start_str.replace("Z", "+00:00")
                    start_dt = datetime.fromisoformat(start_clean)
                    now = datetime.now(timezone.utc)
                    if start_dt.tzinfo is None:
                        start_dt = start_dt.replace(tzinfo=timezone.utc)
                    diff_min = int((start_dt - now).total_seconds() / 60)
                    if 0 < diff_min <= 120:
                        max_sum = BOX_TEXT_WIDTH - len(f" in {diff_min} min.")
                        lines.append(
                            f"{summary[:max_sum]} in {diff_min} min."
                        )
                except (ValueError, TypeError):
                    pass

    # Energy patterns (time of day)
    hour = datetime.now().hour
    energy = prefs.get("energy_patterns", {})
    if 12 <= hour <= 14 and energy.get("after_lunch") == "low":
        lines.append("Post-lunch dip — walk it off")
    elif hour >= 16 and energy.get("evening") == "low":
        lines.append("Evening — move around a bit")

    return [ln[:BOX_TEXT_WIDTH] for ln in lines]
