import argparse
import json
import sys
try:
    from .catalog import EXIT_CODES, SnapshotError, load_snapshot, migrate_config, publish_manual, resolve, tier_from_config
except ImportError:
    import os
    sys.path.insert(0, os.path.dirname(__file__))
    from catalog import EXIT_CODES, SnapshotError, load_snapshot, migrate_config, publish_manual, resolve, tier_from_config

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
