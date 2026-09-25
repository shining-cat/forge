#!/usr/bin/env python3
"""
Batch setup for model catalog (non-interactive).
Usage: setup-models-batch.py model1 model2 model3 ... > catalog.json
"""

import json
import sys
from datetime import datetime
from pathlib import Path

# Import setup_models functions
script_dir = Path(__file__).parent
sys.path.insert(0, str(script_dir))
from setup_models import parse_models, infer_vendor, infer_tier, build_record, build_catalog, validate_catalog

def main():
    if len(sys.argv) < 2:
        print("Usage: setup-models-batch.py model1 model2 model3 ...", file=sys.stderr)
        sys.exit(1)
    
    # Parse model arguments
    models_input = "\n".join(sys.argv[1:])
    models = parse_models(models_input)
    
    if not models:
        print("No valid models found", file=sys.stderr)
        sys.exit(1)
    
    # Build records
    records = []
    for model in models:
        # Use inferred values or ask
        vendor = model["vendor"] or "Unknown"
        tier = model["inferred_tier"] or "standard"
        
        record = build_record(
            model_id=model["id"],
            vendor=vendor,
            tier=tier,
            dispatch_id=model["id"],  # Use model ID as dispatch_id
        )
        records.append(record)
    
    # Build catalog
    catalog = build_catalog(records)
    
    # Validate
    is_valid, error = validate_catalog(catalog)
    if not is_valid:
        print(f"Catalog validation failed: {error}", file=sys.stderr)
        sys.exit(1)
    
    # Output as JSON
    print(json.dumps(catalog, indent=2))

if __name__ == "__main__":
    main()
