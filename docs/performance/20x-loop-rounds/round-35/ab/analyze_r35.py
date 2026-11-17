#!/usr/bin/env python3
"""Round-35 A/B analyzer (archived; reconstructed for v3 and validated
against the v2 summaries it must reproduce exactly).

Input: a receipt directory with pair{1..6}-{baseline,candidate}-{mode}.log
for modes {1, streaming, activity, edit-lines, presentation-token}.
Output: summary JSON {metric: {baseline_median, baseline_samples,
candidate_median, candidate_samples, change_percent, max_spread_percent,
worst_pair_percent}}.

Key-naming conventions (reconstructed from the v2 summary key set):
  mode 1:               cold@<source_slots>, append@<source_slots>
  activity:             edit_stats@<messages>, running_ids@<messages>,
                        activity_init@<messages>, single_turn_activity@<messages>
  streaming top (2sp):  <name> verbatim; older_page_full_chain
  streaming stage (4sp):stage_<name>  (first breakdown + older_page subs)
  streaming page (6sp): page_<name>   (older_page breakdown)
  edit-lines JSON:      edit<source_rows>_<case> for source_rows in {64, 512}
  presentation-token:   token<turns>_<field> (same-id-tail-token-replacement),
                        longtail<turns>_<field> (long-tail-stream);
                        fields = the 10 _ms sample fields; per-pair value =
                        median over samples (all-zero sides dropped, which
                        is why the Mac v2 summary has 90 keys and Linux 96).
Metrics whose samples are all zero on BOTH sides are dropped (apply,
input_comparison, summary — matches the v2 key set).

Classifier (loop rules): change = (cand_med - base_med)/base_med*100;
spread per side = (max-min)/min*100, max_spread = max over both sides;
worst_pair_percent = max over pairs of per-pair change percent; adoption
requires |change| > max_spread AND worst pair same-signed (separation).
"""
import json
import re
import statistics
import sys
from pathlib import Path

TOKEN_FIELDS = [
    "fixture_tail_replace_ms", "input_comparison_ms", "narrative_ms",
    "retained_cost_ms", "row_projection_ms", "state_reset_ms",
    "summary_ms", "tool_projection_ms", "total_ms", "turn_projection_ms",
]


def parse_streaming(text):
    out = {}
    ctx = "top"
    for line in text.splitlines():
        if not line.strip() or "median_ms" not in line:
            if "presentation_update breakdown" in line:
                indent = len(line) - len(line.lstrip())
                ctx = "stage" if indent <= 2 else "page"
            continue
        indent = len(line) - len(line.lstrip())
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s+median_ms=\s*([0-9.]+)", line)
        if not m:
            continue
        name, value = m.group(1), float(m.group(2))
        if indent <= 2:
            out[name] = value
            ctx = "opsub" if name == "older_page_full_chain" else "top"
        elif indent <= 4:
            prefix = {"stage": "stage_", "page": "page_", "opsub": "stage_", "top": ""}[ctx]
            out[prefix + name] = value
        else:
            out["page_" + name] = value
    return out


def parse_mode1(text):
    out = {}
    for line in text.splitlines():
        m = re.search(r"source_slots=(\d+)", line)
        if not m:
            continue
        n = m.group(1)
        for field, key in (("cold_median_ms", "cold@"), ("append_median_ms", "append@")):
            fm = re.search(field + r"=([0-9.]+)", line)
            if fm:
                out[key + n] = float(fm.group(1))
    return out


def parse_activity(text):
    out = {}
    for line in text.splitlines():
        if not line.startswith("activity_bench"):
            continue
        mm = re.search(r"messages=(\d+)", line)
        if not mm:
            continue
        n = mm.group(1)
        if "single_turn_calls=" in line:
            fm = re.search(r"activity_init_median_ms=([0-9.]+)", line)
            if fm:
                out["single_turn_activity@" + n] = float(fm.group(1))
            continue
        for field, key in (("edit_stats_median_ms", "edit_stats@"),
                           ("running_ids_median_ms", "running_ids@"),
                           ("activity_init_median_ms", "activity_init@")):
            fm = re.search(field + r"=([0-9.]+)", line)
            if fm:
                out[key + n] = float(fm.group(1))
    return out


def parse_editlines(text):
    d = json.loads(text)
    out = {}
    for r in d["results"]:
        if r["source_rows"] in (64, 512):
            out["edit%d_%s" % (r["source_rows"], r["case"])] = r["median_ms"]
    return out


def parse_token(text):
    d = json.loads(text)
    out = {}
    for r in d["results"]:
        if r["scenario"] == "same-id-tail-token-replacement":
            prefix = "token%d_" % r["fixture_turns"]
        elif r["scenario"] == "long-tail-stream":
            prefix = "longtail%d_" % r["fixture_turns"]
        else:
            continue
        for field in TOKEN_FIELDS:
            vals = [s[field] for s in r["samples"] if field in s]
            if vals:
                out[prefix + field] = statistics.median(vals)
    return out


PARSERS = {
    "1": parse_mode1,
    "streaming": parse_streaming,
    "activity": parse_activity,
    "edit-lines": parse_editlines,
    "presentation-token": parse_token,
}


def collect(receipt_dir):
    per = {"baseline": {}, "candidate": {}}  # metric -> [6 values]
    for pair in range(1, 7):
        for variant in ("baseline", "candidate"):
            for mode, parser in PARSERS.items():
                p = Path(receipt_dir) / ("pair%d-%s-%s.log" % (pair, variant, mode))
                text = p.read_text(errors="replace")
                for key, value in parser(text).items():
                    per[variant].setdefault(key, []).append(value)
    return per


def summarize(receipt_dir, pairs=6):
    per = collect(receipt_dir)
    summary = {}
    for key in sorted(set(per["baseline"]) & set(per["candidate"])):
        b, c = per["baseline"][key], per["candidate"][key]
        if len(b) != pairs or len(c) != pairs:
            print("WARN: %s has %d/%d samples" % (key, len(b), len(c)), file=sys.stderr)
        if all(v == 0 for v in b) and all(v == 0 for v in c):
            continue  # all-zero on both sides: unclassifiable, dropped (v2 rule)
        bm, cm = statistics.median(b), statistics.median(c)
        # v2 behavior: zero baseline median is NOT skipped; change is NaN
        # (JSON NaN, as in the v2 reference files).
        change = (cm - bm) / bm * 100.0 if bm != 0 else float("nan")

        def spread(vals):
            lo, hi = min(vals), max(vals)
            return (hi - lo) / lo * 100.0 if lo > 0 else 0.0

        pos = [(bi, ci) for bi, ci in zip(b, c) if bi > 0]
        worst = max((ci - bi) / bi * 100.0 for bi, ci in pos) if pos else 0.0
        summary[key] = {
            "baseline_median": bm,
            "baseline_samples": b,
            "candidate_median": cm,
            "candidate_samples": c,
            "change_percent": change,
            "max_spread_percent": max(spread(b), spread(c)),
            "worst_pair_percent": worst,
        }
    return summary


def validate(produced, reference_path):
    ref = json.load(open(reference_path))
    produced_keys, ref_keys = set(produced), set(ref)
    ok = True
    if produced_keys != ref_keys:
        ok = False
        print("KEY MISMATCH only-produced=%s only-ref=%s"
              % (sorted(produced_keys - ref_keys), sorted(ref_keys - produced_keys)))
    worst_delta = 0.0
    for k in sorted(produced_keys & ref_keys):
        for field in ("baseline_median", "candidate_median", "change_percent",
                      "max_spread_percent", "worst_pair_percent"):
            if field in ref[k]:
                d = abs(produced[k][field] - ref[k][field])
                rel = d / max(abs(ref[k][field]), 1e-9)
                if rel > 1e-6 and d > 1e-9:
                    ok = False
                    print("FIELD MISMATCH %s.%s produced=%r ref=%r" % (k, field, produced[k][field], ref[k][field]))
                worst_delta = max(worst_delta, d)
        for field in ("baseline_samples", "candidate_samples"):
            if len(produced[k][field]) != len(ref[k][field]) or any(
                    abs(a - b) > 1e-9 for a, b in zip(produced[k][field], ref[k][field])):
                ok = False
                print("SAMPLES MISMATCH %s.%s produced=%r ref=%r" % (k, field, produced[k][field], ref[k][field]))
    print("VALIDATE %s: %d metrics, worst field delta %.3g" % ("OK" if ok else "FAILED", len(ref), worst_delta))
    return ok


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "validate":
        produced = summarize(sys.argv[2])
        sys.exit(0 if validate(produced, sys.argv[3]) else 1)
    else:
        out = summarize(sys.argv[2])
        Path(sys.argv[3]).write_text(json.dumps(out, indent=1))
        print("wrote %s (%d metrics)" % (sys.argv[3], len(out)))
