import argparse
import json
import os
import sys
import tempfile
try:
    from .catalog import EXIT_CODES, SnapshotError, load_snapshot, migrate_config, publish_manual, resolve, tier_from_config, TIERS
except ImportError:
    import os
    sys.path.insert(0, os.path.dirname(__file__))
    from catalog import EXIT_CODES, SnapshotError, load_snapshot, migrate_config, publish_manual, resolve, tier_from_config, TIERS

def _coverage(snapshot_path, binding):
    if not binding.strip():
        raise SnapshotError("binding must be non-empty")
    snapshot = load_snapshot(snapshot_path)
    tiers = {tier: resolve(snapshot, tier, active_binding=binding)["status"] for tier in TIERS}
    missing = [tier for tier in TIERS if tiers[tier] != "resolved"]
    return {"status": "complete" if not missing else "incomplete", "binding": binding,
            "tiers": tiers, "missing_tiers": missing}

def _mark_complete(config):
    with open(config, "rb") as stream:
        original = stream.read()
    lines = original.splitlines(keepends=True)
    found = False
    updated = []
    for line in lines:
        if line.startswith(b"ONBOARDING_COMPLETE="):
            ending = b"\r\n" if line.endswith(b"\r\n") else b"\n" if line.endswith(b"\n") else b""
            updated.append(b"ONBOARDING_COMPLETE=true" + ending)
            found = True
        else:
            updated.append(line)
    if not found:
        if original and not original.endswith((b"\n", b"\r")):
            updated.append(b"\n")
        updated.append(b"ONBOARDING_COMPLETE=true\n")
    result = b"".join(updated)
    if result == original:
        return
    directory = os.path.dirname(os.path.abspath(config))
    fd, temporary = tempfile.mkstemp(prefix=".forge-onboarding.", dir=directory)
    try:
        os.fchmod(fd, os.stat(config).st_mode & 0o777)
        with os.fdopen(fd, "wb") as stream:
            stream.write(result)
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="forge-model-catalog")
    sub = parser.add_subparsers(dest="command")
    resolve_p = sub.add_parser("resolve")
    resolve_p.add_argument("--snapshot")
    resolve_p.add_argument("--tier")
    resolve_p.add_argument("--role")
    resolve_p.add_argument("--config")
    resolve_p.add_argument("--capability", action="append", default=[])
    resolve_p.add_argument("--binding")
    coverage = sub.add_parser("check-coverage")
    coverage.add_argument("--snapshot")
    coverage.add_argument("--binding", required=True)
    entry = sub.add_parser("onboarding-status")
    entry.add_argument("--snapshot", required=True)
    entry.add_argument("--binding", required=True)
    entry.add_argument("--config", required=True)
    finish = sub.add_parser("finish-onboarding")
    finish.add_argument("--snapshot", required=True)
    finish.add_argument("--binding", required=True)
    finish.add_argument("--config", required=True)
    pub = sub.add_parser("publish")
    pub.add_argument("--input", required=True)
    pub.add_argument("--output")
    mig = sub.add_parser("migrate")
    mig.add_argument("--config", required=True)
    mig.add_argument("--metadata")
    args = parser.parse_args(argv)
    try:
        if args.command == "publish":
            print(json.dumps(publish_manual(args.input, args.output), sort_keys=True)); return 0
        if args.command == "migrate":
            print(json.dumps(migrate_config(args.config, args.metadata), sort_keys=True)); return 0
        if args.command == "check-coverage":
            result = _coverage(args.snapshot, args.binding)
            print(json.dumps(result, sort_keys=True))
            return 0 if result["status"] == "complete" else EXIT_CODES["no_match"]
        if args.command == "finish-onboarding":
            result = _coverage(args.snapshot, args.binding)
            if result["status"] != "complete":
                print(json.dumps(result, sort_keys=True))
                return EXIT_CODES["no_match"]
            _mark_complete(args.config)
            print(json.dumps({**result, "onboarding_complete": True}, sort_keys=True))
            return 0
        if args.command == "onboarding-status":
            with open(args.config, encoding="utf-8") as stream:
                completed = any(line.rstrip("\r\n") == "ONBOARDING_COMPLETE=true" for line in stream)
            try:
                result = _coverage(args.snapshot, args.binding)
            except SnapshotError as exc:
                result = {"status": "invalid", "binding": args.binding,
                          "missing_tiers": list(TIERS), "error": str(exc)}
            result["action"] = ("continue" if completed and result["status"] == "complete"
                                else "map-models-only" if completed else "full-onboarding")
            result["skip_model_mapping"] = result["status"] == "complete"
            print(json.dumps(result, sort_keys=True))
            return 0
        if args.command != "resolve":
            parser.error("a command is required")
        tier = args.tier
        if tier is None:
            if args.role and args.config:
                tier = tier_from_config(args.config, args.role)
            else:
                tier = "inherit"
        result = resolve(load_snapshot(args.snapshot), tier, args.capability, role=args.role, active_binding=args.binding)
        print(json.dumps(result, sort_keys=True)); return EXIT_CODES[result["status"]]
    except (OSError, ValueError, SnapshotError) as exc:
        print(json.dumps({"status": "invalid", "error": str(exc)}))
        return EXIT_CODES["invalid"]

if __name__ == "__main__":
    sys.exit(main())
