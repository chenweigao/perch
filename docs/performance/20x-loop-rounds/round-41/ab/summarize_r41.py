#!/usr/bin/env python3
"""Round-41 A/B summarizer (lineage: round-39 F1 corrected classifier).

Usage: summarize_r41.py <results-dir> <label>
Parses pair<N>-<variant>-<mode>.log, extracts every `median_ms=` metric line,
and per metric computes: per-variant median of the six per-pair medians,
per-variant spread = (max-min)/min*100 over the six, median change %, and
per-pair same-direction separation count. Adoption classifier (round-39 F1:
spread from the SAME metric in the SAME batch, both-sided max):
  separated iff |change%| > max(spread_base, spread_cand) AND 6/6 pairs
  separate in the same direction.
"""
import glob
import json
import os
import re
import sys
from statistics import median

LINE = re.compile(r"^\s*(\S+?)\s*median_ms=\s*([0-9.]+)")


def parse(path):
    out = {}
    with open(path) as fh:
        for line in fh:
            m = LINE.match(line)
            if m:
                name, value = m.group(1), float(m.group(2))
                # metric names may glue to the column (commentary_x median_ms=)
                name = name.rstrip()
                out[name] = value
    return out


def main():
    results_dir, label = sys.argv[1], sys.argv[2]
    data = {}  # metric -> variant -> [six values]
    pairs_seen = set()
    for path in sorted(glob.glob(os.path.join(results_dir, "pair*-*.log"))):
        base = os.path.basename(path)[:-4]
        m = re.match(r"pair(\d+)-(baseline|candidate)-(.+)", base)
        if not m:
            continue
        pair, variant, mode = m.groups()
        pairs_seen.add(int(pair))
        metrics = parse(path)
        for name, value in metrics.items():
            key = name if mode == "streaming" else f"{mode}:{name}"
            data.setdefault(key, {}).setdefault(variant, {})[int(pair)] = value
    n_pairs = len(pairs_seen)
    summary = {"label": label, "pairs": n_pairs, "metrics": {}}
    for metric in sorted(data):
        variants = data[metric]
        if "baseline" not in variants or "candidate" not in variants:
            continue
        bvals = [variants["baseline"][p] for p in sorted(variants["baseline"])]
        cvals = [variants["candidate"][p] for p in sorted(variants["candidate"])]
        if len(bvals) < n_pairs or len(cvals) < n_pairs:
            continue
        bmed, cmed = median(bvals), median(cvals)
        bspread = (max(bvals) - min(bvals)) / min(bvals) * 100 if min(bvals) > 0 else 0.0
        cspread = (max(cvals) - min(cvals)) / min(cvals) * 100 if min(cvals) > 0 else 0.0
        change = (cmed - bmed) / bmed * 100 if bmed else 0.0
        band = max(bspread, cspread)
        faster = sum(1 for b, c in zip(bvals, cvals) if c < b)
        slower = sum(1 for b, c in zip(bvals, cvals) if c > b)
        separated = abs(change) > band and (faster == n_pairs or slower == n_pairs)
        summary["metrics"][metric] = {
            "base_median": round(bmed, 4), "cand_median": round(cmed, 4),
            "change_pct": round(change, 2),
            "base_spread_pct": round(bspread, 2), "cand_spread_pct": round(cspread, 2),
            "noise_band_pct": round(band, 2),
            "pairs_cand_faster": faster, "pairs_cand_slower": slower,
            "separated": separated,
            "base_values": [round(v, 4) for v in bvals],
            "cand_values": [round(v, 4) for v in cvals],
        }
    print(json.dumps(summary, indent=1))
    # human table for the key metrics
    keys = [k for k in summary["metrics"]
            if k in ("commentary_chain_total", "chain_total") or "older_page" in k
            or "append" in k or k.startswith("commentary_presentation")
            or k.startswith("commentary_narrative")]
    print(f"\n== {label} key metrics ==", file=sys.stderr)
    for k in sorted(set(keys)):
        m = summary["metrics"][k]
        print(f"{k:38s} {m['base_median']:9.4f} -> {m['cand_median']:9.4f} "
              f"({m['change_pct']:+6.2f}%) band={m['noise_band_pct']:5.2f}% "
              f"sep={m['pairs_cand_faster']}/{n_pairs}f {m['pairs_cand_slower']}/{n_pairs}s "
              f"{'SEPARATED' if m['separated'] else 'within-noise'}", file=sys.stderr)


if __name__ == "__main__":
    main()
