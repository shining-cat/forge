#!/usr/bin/env python3
"""
Forge model catalog setup backend.
Handles parsing, validation, schema checking, and resolve testing.
"""

import json
import sys
import os
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Tuple, Optional

# Infer vendor from model name
VENDOR_PATTERNS = {
    "claude": "Anthropic",
    "gpt": "OpenAI",
    "gemini": "Google",
}

# Infer tier from model name (deprecated: use infer_tier function logic)
TIER_PATTERNS = {
    "minimal": ["haiku", "mini"],
    "economy": ["flash", "3.8"],
    "standard": ["sonnet", "gpt-5.4", "gpt-5.3"],
    "premium": ["opus", "gpt-5.6", "luna", "terra", "sol"],
}

NEUTRAL_TIERS = ["minimal", "economy", "standard", "premium"]


def infer_vendor(model_id: str) -> Optional[str]:
    """Infer vendor from model ID."""
    for pattern, vendor in VENDOR_PATTERNS.items():
        if pattern.lower() in model_id.lower():
            return vendor
    return None


def infer_tier(model_id: str) -> Optional[str]:
    """Infer tier from model ID based on naming patterns."""
    model_lower = model_id.lower()
    
    # premium: full-strength reasoning + extended thinking (check first, most specific)
    if any(p in model_lower for p in ["opus", "gpt-5.6", "luna", "terra", "sol"]):
        return "premium"
    
    # standard: balanced reasoning
    if any(p in model_lower for p in ["sonnet", "gpt-5.4", "gpt-5.3"]):
        return "standard"
    
    # economy: lightweight reasoning
    if any(p in model_lower for p in ["flash", "3.8"]):
        return "economy"
    
    # minimal: ultra-lightweight, admin-only tasks (check last, avoid substring collisions)
    if "haiku" in model_lower:
        return "minimal"
    
    return None


def parse_models(input_text: str) -> List[Dict]:
    """
    Parse user input (one per line or comma-separated) into model records.
    Returns list of dicts with: id, vendor (inferred), tier (inferred)
    """
    models = []
    
    # Split by newline or comma
    lines = input_text.strip().split('\n')
    for line in lines:
        # Handle comma-separated on same line
        for item in line.split(','):
            item = item.strip()
            if not item:
                continue
            
            # Extract model ID (first word/token)
            model_id = item.split()[0]
            
            # Infer vendor and tier
            vendor = infer_vendor(model_id)
            tier = infer_tier(model_id)
            
            models.append({
                "id": model_id,
                "vendor": vendor,
                "inferred_tier": tier,
                "raw_input": item,
            })
    
    return models


def validate_schema(record: Dict) -> Tuple[bool, Optional[str]]:
    """
    Validate a catalog record against schema requirements.
    Returns (is_valid, error_message).
    """
    # Check required fields
    if "identity" not in record:
        return False, "Missing 'identity' field"
    
    identity = record["identity"]
    if not isinstance(identity, dict):
        return False, "identity must be a dict"
    
    if "vendor" not in identity or not identity["vendor"]:
        return False, "identity.vendor cannot be empty"
    
    if "id" not in identity or not identity["id"]:
        return False, "identity.id cannot be empty"
    
    if "tier" not in record:
        return False, "Missing 'tier' field"
    
    if record["tier"] not in NEUTRAL_TIERS:
        return False, f"tier must be one of {NEUTRAL_TIERS}, got {record['tier']}"
    
    if "evidence" not in record or not isinstance(record["evidence"], list):
        return False, "evidence must be a non-empty array"
    
    if len(record["evidence"]) == 0:
        return False, "evidence array cannot be empty"
    
    if "bindings" not in record or not isinstance(record["bindings"], list):
        return False, "bindings must be a non-empty array"
    
    if len(record["bindings"]) == 0:
        return False, "bindings array cannot be empty"
    
    # Validate bindings
    for binding in record["bindings"]:
        if "runtime" not in binding:
            return False, "binding must have 'runtime' field"
        if "active" not in binding:
            return False, "binding must have 'active' field"
        if binding["active"] and "dispatch_id" not in binding:
            return False, f"active binding for {binding.get('runtime')} must have dispatch_id"
    
    return True, None


def build_record(model_id: str, vendor: str, tier: str, 
                 dispatch_id: Optional[str] = None) -> Dict:
    """
    Build a catalog record with required schema fields.
    """
    now = datetime.utcnow().isoformat() + "Z"
    
    record = {
        "identity": {
            "vendor": vendor,
            "id": model_id,
        },
        "tier": tier,
        "capabilities": [],  # User can edit later if needed
        "evidence": [
            {
                "kind": "manual",
                "captured_at": now,
                "source": "user-setup",
            }
        ],
        "bindings": [
            {
                "runtime": "copilot-cli",
                "active": dispatch_id is not None,
                "dispatch_id": dispatch_id,
                "captured_at": now,
            }
        ],
    }
    
    return record


def build_catalog(records: List[Dict]) -> Dict:
    """
    Build complete catalog JSON with schema metadata.
    """
    now = datetime.utcnow()
    
    catalog = {
        "schema_version": 1,
        "clock": {
            "source": "manual",
            "timezone": "UTC",
            "captured_at": now.isoformat() + "Z",
        },
        "records": records,
    }
    
    return catalog


def validate_catalog(catalog: Dict) -> Tuple[bool, Optional[str]]:
    """
    Validate entire catalog structure.
    """
    if "schema_version" not in catalog:
        return False, "Missing schema_version"
    
    if "clock" not in catalog:
        return False, "Missing clock"
    
    clock = catalog["clock"]
    if "source" not in clock or clock["source"] not in ["manual", "system"]:
        return False, "clock.source must be 'manual' or 'system'"
    
    if "records" not in catalog or not isinstance(catalog["records"], list):
        return False, "records must be a non-empty array"
    
    # Validate each record
    for record in catalog["records"]:
        is_valid, error = validate_schema(record)
        if not is_valid:
            model_id = record.get("identity", {}).get("id", "unknown")
            return False, f"Record {model_id}: {error}"
    
    return True, None


def load_catalog_python(catalog_path: str) -> Optional[Dict]:
    """
    Load catalog JSON and return Python dict. Used for resolve testing.
    """
    try:
        with open(catalog_path, 'r') as f:
            return json.load(f)
    except Exception as e:
        print(f"Error loading catalog: {e}", file=sys.stderr)
        return None


def resolve_models(catalog_path: str, test_tiers: List[str]) -> Dict:
    """
    Test resolve() for each tier in test_tiers.
    Returns dict of {tier: {success: bool, dispatch_id: str, error: str}}
    """
    catalog = load_catalog_python(catalog_path)
    if not catalog:
        return {"error": "Could not load catalog"}
    
    results = {}
    records = catalog.get("records", [])
    
    for tier in test_tiers:
        # Find first record matching this tier
        matching = [r for r in records if r.get("tier") == tier]
        if not matching:
            results[tier] = {"success": False, "error": f"No models found with tier={tier}"}
            continue
        
        record = matching[0]
        bindings = record.get("bindings", [])
        active_bindings = [b for b in bindings if b.get("active")]
        
        if not active_bindings:
            results[tier] = {"success": False, "error": "No active bindings"}
            continue
        
        binding = active_bindings[0]
        dispatch_id = binding.get("dispatch_id")
        
        if dispatch_id:
            results[tier] = {
                "success": True,
                "dispatch_id": dispatch_id,
                "model_id": record["identity"]["id"],
            }
        else:
            results[tier] = {"success": False, "error": "No dispatch_id in binding"}
    
    return results


if __name__ == "__main__":
    # CLI interface for testing
    import argparse
    
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command")
    
    # parse: read models from stdin
    parse_cmd = subparsers.add_parser("parse")
    
    # validate: validate a catalog JSON file
    validate_cmd = subparsers.add_parser("validate")
    validate_cmd.add_argument("catalog_path")
    
    # resolve-test: test resolve for given tiers
    resolve_cmd = subparsers.add_parser("resolve-test")
    resolve_cmd.add_argument("catalog_path")
    resolve_cmd.add_argument("--tiers", default="minimal,economy,standard,premium")
    
    # infer: infer vendor and tier for a model
    infer_cmd = subparsers.add_parser("infer")
    infer_cmd.add_argument("model_id")
    
    args = parser.parse_args()
    
    if args.command == "parse":
        input_text = sys.stdin.read()
        models = parse_models(input_text)
        print(json.dumps(models, indent=2))
    
    elif args.command == "validate":
        catalog = load_catalog_python(args.catalog_path)
        if catalog:
            is_valid, error = validate_catalog(catalog)
            if is_valid:
                print(f"✓ Catalog is valid")
                sys.exit(0)
            else:
                print(f"✗ Catalog validation failed: {error}", file=sys.stderr)
                sys.exit(1)
        else:
            sys.exit(1)
    
    elif args.command == "resolve-test":
        tiers = args.tiers.split(",")
        results = resolve_models(args.catalog_path, tiers)
        print(json.dumps(results, indent=2))
    
    elif args.command == "infer":
        vendor = infer_vendor(args.model_id)
        tier = infer_tier(args.model_id)
        print(json.dumps({
            "model_id": args.model_id,
            "vendor": vendor,
            "tier": tier,
        }, indent=2))
    
    else:
        parser.print_help()
