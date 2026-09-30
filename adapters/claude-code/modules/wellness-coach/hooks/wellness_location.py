#!/usr/bin/env python3
"""Validated, consent-gated wellness storage within the configured vault."""
import argparse
import fcntl
import json
import os
import shutil
import sys
from pathlib import Path

FILES = ("wellness-preferences.json", "wellness-runtime.json",
         "wellness-activity-log.md", "wellness-idle-log.json",
         "wellness-calendar-cache.json")
DEFAULT_DIRECTORY = "wellness-coach"


def config_path():
    return Path(os.environ.get("FORGE_CONF_OVERRIDE") or
                Path(os.environ.get("CLAUDE_HOME", Path.home() / ".claude")) / "forge.conf")


def shared_dir():
    conf = config_path()
    values = [line.split("=", 1)[1].strip() for line in conf.read_text().splitlines()
              if line.startswith("VAULT_PATH=")]
    if len(values) != 1 or not values[0] or not Path(values[0]).is_absolute():
        raise ValueError("VAULT_PATH must be one absolute configured vault directory")
    vault = Path(values[0])
    if not vault.is_dir():
        raise ValueError("configured vault is not a directory")
    shared = vault / "_shared"
    if not shared.is_dir() or shared.is_symlink() or not shared.resolve().is_relative_to(vault.resolve()):
        raise ValueError("vault _shared must be a real directory inside the vault")
    return shared


def validated_directory(shared, directory):
    if not isinstance(directory, str) or not directory or directory.startswith("/"):
        raise ValueError("wellness directory must be a relative subpath of _shared")
    parts = Path(directory).parts
    if any(part in ("", ".", "..") for part in directory.split("/")) or "\\" in directory:
        raise ValueError("invalid wellness directory component")
    candidate = shared.joinpath(*parts)
    current = shared
    for part in parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("wellness directory must not traverse a symlink")
    if not candidate.resolve().is_relative_to(shared.resolve()):
        raise ValueError("wellness directory escapes vault _shared")
    return candidate


def location():
    shared = shared_dir()
    locator = shared / "wellness-location.json"
    if locator.is_symlink():
        raise ValueError("wellness locator must not be a symlink")
    if not locator.exists():
        return shared
    data = json.loads(locator.read_text())
    if not isinstance(data, dict) or set(data) != {"directory"}:
        raise ValueError("invalid wellness locator")
    dest = validated_directory(shared, data["directory"])
    if not dest.is_dir():
        raise ValueError("wellness destination missing")
    return dest


def consented():
    shared = shared_dir()
    locator = shared / "wellness-location.json"
    return (locator.exists() or locator.is_symlink()) and location() != shared


def file_path(name):
    if name not in FILES and name not in ("wellness-idle-sampler.log",):
        raise ValueError("unsupported wellness file")
    target = location() / name
    if not target.resolve().is_relative_to(location().resolve()):
        raise ValueError("wellness file escapes destination")
    return target


def safe_sidecar(path):
    path = Path(path)
    if not path.resolve().is_relative_to(location().resolve()):
        raise ValueError("wellness sidecar escapes destination")
    return path


def prepare(directory, old_tooling_stopped=False):
    """Called only after explicit consent and confirmation all old writers stopped."""
    shared = shared_dir()
    locator = shared / "wellness-location.json"
    if not old_tooling_stopped:
        raise ValueError("stop old CLI sessions and LaunchAgents before migration")
    with (shared / "wellness-location.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if locator.exists() or locator.is_symlink():
            raise ValueError("locator already exists; refusing to replace it")
        target = validated_directory(shared, directory)
        if target == shared or (target.exists() and
                                (not target.is_dir() or any(target.iterdir()))):
            raise ValueError("destination must be an empty directory")
        tmp = shared / "wellness-location.json.pending"
        if tmp.exists() or tmp.is_symlink():
            raise ValueError("pending locator already exists")
        created = not target.exists()
        target.mkdir(parents=True, exist_ok=True)
        pending_created = False
        try:
            for name in FILES:
                source = shared / name
                if source.is_symlink():
                    raise ValueError(f"legacy {name} is a symlink")
                if source.exists():
                    shutil.copy2(source, target / name)
            migrated_prefs = target / "wellness-preferences.json"
            if migrated_prefs.exists():
                data = json.loads(migrated_prefs.read_text())
                if not isinstance(data, dict):
                    raise ValueError("legacy preferences must be a JSON object")
                data["wellness_onboarding_complete"] = False
                data["activity_monitor_enabled"] = False
                migrated_prefs.write_text(json.dumps(data, indent=2) + "\n")
            with tmp.open("x") as f:
                pending_created = True
                json.dump({"directory": directory}, f)
                f.flush()
                os.fsync(f.fileno())
            os.link(tmp, locator)
            tmp.unlink()
        except Exception:
            if pending_created:
                tmp.unlink(missing_ok=True)
            for name in FILES:
                (target / name).unlink(missing_ok=True)
            if created:
                target.rmdir()
            raise
        return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("directory")
    commands.add_parser("consented")
    proposed = commands.add_parser("propose")
    proposed.add_argument("--directory", default=DEFAULT_DIRECTORY)
    path = commands.add_parser("file")
    path.add_argument("name")
    setup = commands.add_parser("prepare")
    setup.add_argument("--directory", default=DEFAULT_DIRECTORY)
    setup.add_argument("--consent", action="store_true")
    setup.add_argument("--old-tooling-stopped", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "directory":
            print(location())
        elif args.command == "propose":
            print(validated_directory(shared_dir(), args.directory))
        elif args.command == "consented":
            if not consented():
                raise ValueError("consent to vault wellness storage before installing monitor")
        elif args.command == "file":
            print(file_path(args.name))
        else:
            if not args.consent:
                raise ValueError("explicit destination consent required")
            print(prepare(args.directory, args.old_tooling_stopped))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"[wellness-location] {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
