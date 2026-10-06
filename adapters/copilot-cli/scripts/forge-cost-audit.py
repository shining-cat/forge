#!/usr/bin/env python3
"""Retrospective provider-native usage: Copilot AI credits and Anthropic estimated USD.

Copilot figures cover every locally recorded CLI session in session-store.db, not
just Forge; other devices and Copilot surfaces are not included. Anthropic figures
use Claude project logs and list prices. Costs are never added across providers.
"""

import argparse
import glob
import json
import os
from pathlib import Path
import sqlite3
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

# Per-tier list pricing, USD per million tokens: input, output, cache-write(5min), cache-read.
# cache-write(5min) = 1.25x input; cache-write(1h) = 2x input = 1.6x the 5min rate;
# cache-read = 0.1x input. Unknown models fall back to the opus (most expensive) tier.
PRICING = {
    "opus":   {"in": 15.0, "out": 75.0, "cw": 18.75, "cr": 1.50},
    "sonnet": {"in": 3.0,  "out": 15.0, "cw": 3.75,  "cr": 0.30},
    "haiku":  {"in": 0.80, "out": 4.0,  "cw": 1.00,  "cr": 0.08},
}
FALLBACK_TIER = "opus"

# 1h-TTL break-even is tier-independent (all rates scale proportionally):
# S/T = (W1 - R) / (W1 - W5), with W1=1.6*W5. Computed here so it stays honest.
def _break_even():
    p = PRICING[FALLBACK_TIER]
    w5, w1, r = p["cw"], p["cw"] * 1.6, p["cr"]
    return (w1 - w5) / (w1 - r)

BREAK_EVEN = _break_even()  # ~0.3947


def tier_for(model):
    m = (model or "").lower()
    for tier in PRICING:
        if tier in m:
            return tier
    return FALLBACK_TIER


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def iter_usage_records(root, cutoff):
    """Yield (model, usage_dict, timestamp, session_file) for every usage record.

    cutoff: a datetime; records strictly older are skipped. None = no window.
    """
    for fp in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        try:
            fh = open(fp, "r")
        except OSError:
            continue
        with fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                msg = obj.get("message") or {}
                usage = msg.get("usage") or obj.get("usage")
                if not usage:
                    continue
                ts = parse_ts(obj.get("timestamp"))
                if cutoff is not None and ts is not None and ts < cutoff:
                    continue
                model = msg.get("model") or obj.get("model") or "unknown"
                yield model, usage, ts, fp


def cost_for(tier, tok):
    p = PRICING[tier]
    return (
        tok["in"] * p["in"] + tok["out"] * p["out"]
        + tok["cw"] * p["cw"] + tok["cr"] * p["cr"]
    ) / 1e6


def aggregate(root, cutoff):
    per_model = defaultdict(lambda: {"in": 0, "out": 0, "cw": 0, "cr": 0, "msgs": 0})
    ts_min = ts_max = None
    for model, usage, ts, _ in iter_usage_records(root, cutoff):
        m = per_model[model]
        m["in"] += usage.get("input_tokens", 0) or 0
        m["out"] += usage.get("output_tokens", 0) or 0
        m["cw"] += usage.get("cache_creation_input_tokens", 0) or 0
        m["cr"] += usage.get("cache_read_input_tokens", 0) or 0
        m["msgs"] += 1
        if ts is not None:
            ts_min = ts if ts_min is None or ts < ts_min else ts_min
            ts_max = ts if ts_max is None or ts > ts_max else ts_max
    return per_model, ts_min, ts_max


def build_report(root, cutoff):
    if not os.path.isdir(root):
        raise FileNotFoundError("Anthropic project log directory not found: %s" % root)
    per_model, ts_min, ts_max = aggregate(root, cutoff)
    models = []
    for model, m in per_model.items():
        total = m["in"] + m["out"] + m["cw"] + m["cr"]
        if total == 0:
            continue  # drop noise rows (e.g. synthetic/telemetry models with no tokens)
        tier = tier_for(model)
        models.append({
            "model": model,
            "tier": tier,
            "input": m["in"],
            "output": m["out"],
            "cache_write": m["cw"],
            "cache_read": m["cr"],
            "total": total,
            "msgs": m["msgs"],
            "cost_usd": round(cost_for(tier, m), 6),
        })
    models.sort(key=lambda d: -d["total"])

    # Grand totals — token sums plus per-type COST (the decision-relevant split;
    # by token count cache_read dwarfs everything at ~0.1x price and misleads).
    g = {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0, "total": 0, "cost_usd": 0.0}
    cost_by_type = {"input": 0.0, "output": 0.0, "cache_write": 0.0, "cache_read": 0.0}
    _cost_key = {"input": "in", "output": "out", "cache_write": "cw", "cache_read": "cr"}
    for d in models:
        for k in ("input", "output", "cache_write", "cache_read", "total"):
            g[k] += d[k]
        g["cost_usd"] += d["cost_usd"]
        p = PRICING[d["tier"]]
        for ctype, pkey in _cost_key.items():
            cost_by_type[ctype] += d[ctype] * p[pkey] / 1e6
    g["cost_usd"] = round(g["cost_usd"], 6)

    # cost_pct: each token-type's share of total cost, and each model's share.
    cost_pct = {}
    if g["cost_usd"]:
        for k in ("input", "output", "cache_write", "cache_read"):
            cost_pct[k] = round(cost_by_type[k] / g["cost_usd"] * 100, 1)
        for d in models:
            d["cost_pct"] = round(d["cost_usd"] / g["cost_usd"] * 100, 1)
    return {
        "provider": "anthropic",
        "scope": "all local Claude project logs (not Forge-only)",
        "cost_unit": "estimated USD at Anthropic list prices",
        "root": root,
        "timestamp_range": {
            "min": ts_min.isoformat() if ts_min else None,
            "max": ts_max.isoformat() if ts_max else None,
        },
        "models": models,
        "grand_total": {**g, "cost_pct": cost_pct},
    }


def build_copilot_report(db_path, cutoff):
    path = Path(db_path).expanduser()
    if not path.is_file():
        raise FileNotFoundError("Copilot usage database not found: %s" % path)

    per_model = defaultdict(lambda: {
        "input": 0, "output": 0, "cache_write": 0, "cache_read": 0,
        "nano_aiu": 0, "calls": 0,
    })
    ts_min = ts_max = None
    with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True) as conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(assistant_usage_events)")}
        required = {
            "model", "input_tokens", "output_tokens", "cache_read_tokens",
            "cache_write_tokens", "total_nano_aiu", "created_at",
        }
        if not required <= columns:
            raise ValueError("Copilot usage database lacks columns: %s" %
                             ", ".join(sorted(required - columns)))
        query = ("SELECT model, input_tokens, output_tokens, cache_read_tokens, "
                 "cache_write_tokens, total_nano_aiu, created_at "
                 "FROM assistant_usage_events")
        for model, inp, out, read, write, nano_aiu, created in conn.execute(query):
            ts = parse_ts(created)
            if ts is None:
                raise ValueError("Invalid Copilot usage timestamp: %r" % created)
            if cutoff is not None and ts < cutoff:
                continue
            if nano_aiu is None:
                raise ValueError("Copilot usage event has no recorded AI units")
            m = per_model[model or "unknown"]
            m["input"] += inp or 0
            m["output"] += out or 0
            m["cache_read"] += read or 0
            m["cache_write"] += write or 0
            m["nano_aiu"] += nano_aiu
            m["calls"] += 1
            ts_min = ts if ts_min is None or ts < ts_min else ts_min
            ts_max = ts if ts_max is None or ts > ts_max else ts_max

    models = []
    totals = {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0,
              "total": 0, "nano_aiu": 0, "calls": 0}
    for model, m in per_model.items():
        total = sum(m[k] for k in ("input", "output", "cache_write", "cache_read"))
        row = {"model": model, **m, "total": total,
               "ai_credits": round(m["nano_aiu"] / 1e9, 6)}
        models.append(row)
        for key in totals:
            totals[key] += row[key]
    models.sort(key=lambda row: -row["nano_aiu"])
    return {
        "provider": "copilot",
        "scope": "all locally recorded Copilot CLI sessions (not Forge-only; excludes other devices/clients)",
        "cost_unit": "AI credits (local nano-AI units / 1e9; not full account billing)",
        "database": str(path),
        "timestamp_range": {
            "min": ts_min.isoformat() if ts_min else None,
            "max": ts_max.isoformat() if ts_max else None,
        },
        "models": models,
        "grand_total": {**totals, "ai_credits": round(totals["nano_aiu"] / 1e9, 6)},
    }


def build_cache_composition(root, cutoff, focus_model):
    # Determine focus model = explicit, else highest-cost model in the report.
    report = build_report(root, cutoff)
    if focus_model is None:
        if not report["models"]:
            return {"model": None, "cache_write_total": 0, "buckets": {}, "saveable_tokens": 0}
        focus_model = max(report["models"], key=lambda d: d["cost_usd"])["model"]

    # Collect (ts, cache_write) per session file, then bucket by intra-session gap.
    per_file = defaultdict(list)
    for model, usage, ts, fp in iter_usage_records(root, cutoff):
        if model != focus_model or ts is None:
            continue
        per_file[fp].append((ts, usage.get("cache_creation_input_tokens", 0) or 0))

    buckets = {"session_start": 0, "le_60s": 0, "le_5min": 0, "saveable_5min_1h": 0, "gt_1h": 0}
    cw_total = 0
    for recs in per_file.values():
        recs.sort(key=lambda r: r[0])
        prev = None
        for ts, cw in recs:
            cw_total += cw
            if prev is None:
                b = "session_start"
            else:
                gap = (ts - prev).total_seconds()
                if gap <= 60:
                    b = "le_60s"
                elif gap <= 300:
                    b = "le_5min"
                elif gap <= 3600:
                    b = "saveable_5min_1h"
                else:
                    b = "gt_1h"
            buckets[b] += cw
            prev = ts

    saveable = buckets["saveable_5min_1h"]
    share = (saveable / cw_total) if cw_total else 0.0
    tier = tier_for(focus_model)
    p = PRICING[tier]
    w5, w1, r = p["cw"], p["cw"] * 1.6, p["cr"]
    cur = cw_total * w5 / 1e6
    new = (cw_total - saveable) * w1 / 1e6 + saveable * r / 1e6
    delta = cur - new  # positive = 1h TTL saves money
    return {
        "model": focus_model,
        "tier": tier,
        "cache_write_total": cw_total,
        "buckets": buckets,
        "saveable_tokens": saveable,
        "saveable_share": round(share, 4),
        "break_even": round(BREAK_EVEN, 4),
        "verdict": "net_saving" if delta > 0 else "net_loss",
        "cost_5min_ttl_usd": round(cur, 4),
        "cost_1h_ttl_usd": round(new, 4),
        "delta_usd": round(delta, 4),
    }


def fmt_tok(n):
    if n >= 1e9:
        return "%.3fb" % (n / 1e9)
    if n >= 1e6:
        return "%.1fM" % (n / 1e6)
    if n >= 1e3:
        return "%.1fK" % (n / 1e3)
    return str(n)


def print_report(rep):
    rng = rep["timestamp_range"]
    print("Anthropic usage — %s" % rep["scope"])
    if rng["min"]:
        print("window: %s → %s" % (rng["min"][:10], rng["max"][:10]))
    if not rep["models"]:
        print("(no usage records found)")
        return
    print("")
    for d in rep["models"]:
        share = "  (%.1f%% of cost)" % d["cost_pct"] if "cost_pct" in d else ""
        print("[%s]  %s tok  $%s%s" % (
            d["model"], fmt_tok(d["total"]), "{:,.2f}".format(d["cost_usd"]), share))
        print("   input %s  output %s  cache_write %s  cache_read %s" % (
            fmt_tok(d["input"]), fmt_tok(d["output"]),
            fmt_tok(d["cache_write"]), fmt_tok(d["cache_read"])))
    g = rep["grand_total"]
    print("")
    print("=== GRAND TOTAL: %s tok  $%s ===" % (
        fmt_tok(g["total"]), "{:,.2f}".format(g["cost_usd"])))
    if g.get("cost_pct"):
        pc = g["cost_pct"]
        print("   cost split: cache_write %.1f%%  cache_read %.1f%%  output %.1f%%  input %.1f%%" % (
            pc["cache_write"], pc["cache_read"], pc["output"], pc["input"]))


def print_copilot_report(rep):
    print("Copilot usage — %s" % rep["scope"])
    print("Cost: %s" % rep["cost_unit"])
    if rep["timestamp_range"]["min"]:
        print("window: %s → %s" % (rep["timestamp_range"]["min"][:10],
                                  rep["timestamp_range"]["max"][:10]))
    if not rep["models"]:
        print("(no local usage records found)")
        return
    for row in rep["models"]:
        print("[%s] %s tok  %.6f AI credits  (%d calls)" %
              (row["model"], fmt_tok(row["total"]), row["ai_credits"], row["calls"]))
        print("   input %s  output %s  cache_write %s  cache_read %s" %
              tuple(fmt_tok(row[k]) for k in ("input", "output", "cache_write", "cache_read")))
    total = rep["grand_total"]
    print("=== ALL LOCAL COPILOT CLI SESSIONS: %s tok  %.6f AI credits ===" %
          (fmt_tok(total["total"]), total["ai_credits"]))


def print_composition(c):
    if not c.get("model"):
        print("(no records for cache-composition)")
        return
    print("Cache-write composition — %s (%s tier)" % (c["model"], c["tier"]))
    print("total cache-write: %s tok" % fmt_tok(c["cache_write_total"]))
    order = [("session_start", "session start"), ("le_60s", "≤60s (active churn)"),
             ("le_5min", "60s–5min"), ("saveable_5min_1h", "5min–1h (SAVEABLE by 1h TTL)"),
             ("gt_1h", ">1h")]
    tot = c["cache_write_total"] or 1
    for key, label in order:
        v = c["buckets"].get(key, 0)
        print("  %-30s %10s tok  (%.1f%%)" % (label, fmt_tok(v), v / tot * 100))
    print("")
    print("saveable share %.1f%%  [1h TTL wins iff > %.1f%%]" % (
        c["saveable_share"] * 100, c["break_even"] * 100))
    print("cost @5min TTL ${:,.2f}  @1h TTL ${:,.2f}  delta ${:,.2f}  → {}".format(
        c["cost_5min_ttl_usd"], c["cost_1h_ttl_usd"], c["delta_usd"], c["verdict"].upper()))


def main(argv):
    ap = argparse.ArgumentParser(add_help=True, description="Provider-native, local cross-session usage audit.")
    ap.add_argument("--provider", choices=("both", "copilot", "anthropic"), default="copilot")
    ap.add_argument(
        "--root",
        default=os.path.expanduser("~/.claude/projects"),
        help="Anthropic Claude project logs",
    )
    ap.add_argument("--copilot-db", default=os.path.join(
        os.environ.get("COPILOT_HOME", os.path.expanduser("~/.copilot")), "session-store.db"),
        help="Copilot CLI local session database")
    ap.add_argument("--days", type=int, default=None, help="only sessions active in the last N days")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--cache-composition", action="store_true", dest="cache_composition")
    ap.add_argument("--model", default=None, help="focus model for --cache-composition")
    args = ap.parse_args(argv)
    if args.cache_composition and args.provider != "anthropic":
        ap.error("--cache-composition requires --provider anthropic (Copilot has different pricing)")
    if args.model and not args.cache_composition:
        ap.error("--model requires --cache-composition")
    if args.days is not None and args.days < 0:
        ap.error("--days must be nonnegative")

    cutoff = None
    if args.days is not None:
        cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)

    try:
        if args.cache_composition:
            result = build_cache_composition(args.root, cutoff, args.model)
            if args.json:
                print(json.dumps(result, indent=2))
            else:
                print_composition(result)
        else:
            reports = {}
            if args.provider in ("both", "copilot"):
                reports["copilot"] = build_copilot_report(args.copilot_db, cutoff)
            if args.provider in ("both", "anthropic"):
                reports["anthropic"] = build_report(args.root, cutoff)
            if args.json:
                print(json.dumps(reports, indent=2))
            else:
                for name, report in reports.items():
                    if name == "copilot":
                        print_copilot_report(report)
                    else:
                        print_report(report)
                    print()
    except (OSError, sqlite3.DatabaseError, ValueError) as exc:
        ap.exit(1, "forge-cost-audit: %s\n" % exc)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
