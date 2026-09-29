#!/usr/bin/env python3
"""Manual, runtime-scoped Forge model-tier setup."""
import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

TIERS = ("minimal", "economy", "standard", "premium")
VENDORS = {"claude-": "Anthropic", "gpt-": "OpenAI", "gemini-": "Google", "kimi-": "Moonshot"}
MODEL_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/+-]*$")


def parse_models(input_text):
    raise RuntimeError("Automatic tier inference is retired; use forge-setup-models.sh to select all four tiers explicitly")


def read_models():
    print("Paste available model IDs, one per line or comma-separated; finish with a blank line:", flush=True)
    models = []
    while True:
        line = sys.stdin.readline()
        if not line or not line.strip():
            break
        for item in line.split(","):
            model = item.strip()
            if not MODEL_ID.fullmatch(model):
                raise ValueError(f"Invalid model ID: {model!r}; enter IDs only")
            if model not in models:
                models.append(model)
    if not models:
        raise ValueError("No models supplied; onboarding remains incomplete")
    return models


def choose(models):
    choices = []
    for tier in TIERS:
        print(f"\nChoose a model for {tier} (the same model may serve several tiers):", flush=True)
        for index, model in enumerate(models, 1):
            print(f"  {index}. {model}", flush=True)
        answer = input("Number or model ID (required): ").strip()
        if answer.isdecimal() and 1 <= int(answer) <= len(models):
            choices.append(models[int(answer) - 1])
        elif answer in models:
            choices.append(answer)
        else:
            raise ValueError(f"Missing or invalid choice for {tier}; catalog and config unchanged")
    return choices


def catalog_for(models, choices, runtime, existing):
    now = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    records = []
    if existing:
        for record in existing["records"]:
            foreign = [binding for binding in record["bindings"] if binding["runtime"] != runtime]
            if foreign:
                if existing["clock"]["source"] == "system":
                    foreign = [{**binding, "active": False} for binding in foreign]
                records.append({**record, "bindings": foreign})
    for tier, model in zip(TIERS, choices):
        vendor = next((name for prefix, name in VENDORS.items() if model.lower().startswith(prefix)), "User supplied")
        records.append({"identity": {"id": model, "vendor": vendor}, "tier": tier,
                        "capabilities": [], "evidence": [{"kind": "declared", "source": "manual", "captured_at": now}],
                        "bindings": [{"runtime": runtime, "active": True, "dispatch_id": model, "captured_at": now}]})
    return {"schema_version": 1, "captured_at": now, "clock": {"source": "manual", "timezone": "UTC"},
            "migration": existing["migration"] if existing else {"status": "manual"},
            "outcomes": existing["outcomes"] if existing else [], "records": records}


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("parse", "validate", "infer", "resolve-test"):
        print("Legacy setup subcommands are retired; run forge-setup-models.sh for explicit four-tier selection",
              file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", choices=("claude", "copilot-cli"), required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    args = parser.parse_args()
    models = read_models()
    choices = choose(models)
    existing = None
    if args.catalog.exists():
        with args.catalog.open(encoding="utf-8") as stream:
            existing = json.load(stream)
        spec = importlib.util.spec_from_file_location("_forge_setup_catalog", args.cli.with_name("catalog.py"))
        if spec is None or spec.loader is None:
            raise ValueError("Catalog validator is unavailable")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # Republish permits expired system data, never future or malformed data.
        module.validate_snapshot(existing, allow_stale_system=True)
    data = catalog_for(models, choices, args.runtime, existing)
    args.catalog.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".forge-catalog.", dir=args.catalog.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
        result = subprocess.run([sys.executable, str(args.cli), "check-coverage", "--snapshot", temporary,
                                 "--binding", args.runtime], capture_output=True, text=True)
        if result.returncode:
            raise ValueError(f"Coverage validation failed: {result.stdout.strip()} {result.stderr.strip()}")
        os.replace(temporary, args.catalog)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Catalog saved to {args.catalog} for {args.runtime}; all four tiers resolved.")


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except (ValueError, OSError, EOFError, json.JSONDecodeError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
