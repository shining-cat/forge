#!/usr/bin/env python3
"""Retired: batch tier inference cannot provide user-owned mappings."""
import sys


def main():
    print("setup-models-batch.py is retired; run forge-setup-models.sh and select all four tiers explicitly", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
