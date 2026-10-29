"""Bake resolved role models into agent-definition frontmatter.

Copilot CLI honors a `model:` frontmatter property when a subagent is dispatched
without an explicit model, so writing the resolved dispatch ID there makes the
role-to-tier binding structural instead of a per-dispatch prompt rule.
"""
import os
import re
import tempfile
from pathlib import Path

try:
    from .catalog import SnapshotError, load_snapshot, resolve, tier_from_config
except ImportError:
    from catalog import SnapshotError, load_snapshot, resolve, tier_from_config

_AGENT = re.compile(r"^forge-(?P<role>[a-z]+)\.agent\.md$")
_MODEL_LINE = re.compile(r"^model:\s*(?P<value>\S+)\s*$")


def split_frontmatter(text):
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip("\r\n") != "---":
        raise SnapshotError("agent file has no frontmatter")
    for index in range(1, len(lines)):
        if lines[index].rstrip("\r\n") == "---":
            return lines[1:index], lines[index:]
    raise SnapshotError("agent file frontmatter is not closed")


def current_model(text):
    head, _ = split_frontmatter(text)
    for line in head:
        match = _MODEL_LINE.match(line.rstrip("\r\n"))
        if match:
            return match.group("value")
    return None


def with_model(text, model):
    head, rest = split_frontmatter(text)
    kept = [line for line in head if not _MODEL_LINE.match(line.rstrip("\r\n"))]
    if model:
        if kept and not kept[-1].endswith("\n"):
            kept[-1] += "\n"
        kept.append(f"model: {model}\n")
    return "".join(["---\n", *kept, *rest])


def desired_model(snapshot_path, config, role, binding, available=None):
    tier = tier_from_config(config, role)
    snapshot = {} if tier == "inherit" else load_snapshot(snapshot_path)
    result = resolve(snapshot, tier, role=role, active_binding=binding, available=available)
    status = result["status"]
    if status == "resolved":
        return {"tier": tier, "status": status, "model": result["dispatch_id"]}
    if status == "inherit":
        return {"tier": tier, "status": status, "model": None}
    return {"tier": tier, "status": status, "model": None,
            "dispatch_id": result.get("dispatch_id"), "suggestion": result.get("suggestion")}


def _write_atomic(path, text):
    directory = os.path.dirname(os.path.abspath(path))
    fd, temporary = tempfile.mkstemp(prefix=".forge-agent.", dir=directory)
    try:
        if os.path.exists(path):
            os.fchmod(fd, os.stat(path).st_mode & 0o777)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def render_agents(snapshot_path, config, binding, src_dir, dest_dir=None, check=False, available=None):
    """Return one report row per forge-*.agent.md; write unless `check`.

    A role whose binding cannot resolve is reported as `error` and its file is
    left exactly as found (never guessed, never inherited by accident).
    """
    dest_dir = dest_dir or src_dir
    rows = []
    for source in sorted(Path(src_dir).glob("forge-*.agent.md")):
        match = _AGENT.match(source.name)
        if not match:
            continue
        role = match.group("role")
        row = {"role": role, "file": source.name}
        try:
            want = desired_model(snapshot_path, config, role, binding, available)
        except (OSError, ValueError, SnapshotError) as exc:
            rows.append({**row, "action": "error", "error": str(exc)})
            continue
        row.update({k: v for k, v in want.items() if v is not None})
        if want["status"] not in ("resolved", "inherit"):
            rows.append({**row, "action": "error"})
            continue
        text = source.read_text(encoding="utf-8")
        have = current_model(text)
        row["current"] = have
        target = Path(dest_dir) / source.name
        in_place = target.exists() and target.samefile(source)
        if have == want["model"] and in_place:
            rows.append({**row, "action": "unchanged"})
            continue
        if check:
            rows.append({**row, "action": "drift"})
            continue
        os.makedirs(dest_dir, exist_ok=True)
        _write_atomic(str(target), with_model(text, want["model"]))
        rows.append({**row, "action": "written"})
    return rows
