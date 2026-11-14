#!/usr/bin/env python3
"""Round-16 A/B summarizer: pair logs -> summary.json (one platform dir).

Statistic definitions (reverse-validated against the round-15 v2 JSONs before
first use; see self-check at the bottom):
- per-metric baseline_samples/candidate_samples: one median value per pair,
  in pair order (exactly 6 required)
- median: statistics.median (average of the two middle samples for n=6)
- change_percent: (median(cand) - median(base)) / median(base) * 100
- worst_pair_percent: max over pairs of (cand_i - base_i) / base_i * 100
- max_spread_percent: max over the two variants of (max-min)/min * 100
- positives_beyond_spread: rounded-2dp change > rounded-2dp spread AND
  rounded-2dp worst > 0 (review NB5: compare rounded values, not floats)

Metric extraction rules:
- mode "1":  source_slots=N ... cold_median_ms=X ... append_median_ms=Z
             -> cold@N, append@N
- streaming: 'name median_ms=V' by indent: 2 -> name, 4 -> stage_name,
             6 -> page_name (find_bar_cold_query included automatically)
- activity:  turns=T messages=M edit_stats_median_ms=... running_ids_median_ms=...
             activity_init_median_ms=...  -> edit_stats@M, running_ids@M, activity_init@M
             single_turn_calls=C messages=M activity_init_median_ms=V
             -> single_turn_activity@M
- edit-lines JSON: results with source_rows in {64, 512}: edit{rows}_{case} = median_ms
- presentation-token JSON: per fixture_turns, per *_ms field:
             token{turns}_{field} = statistics.median over the per-update samples
- drop metrics whose samples are all zero on both sides (print-grid zeros)

Usage: summarize_r16.py <pair-log-dir> <out-summary.json>
"""
import json
import pathlib
import re
import statistics
import sys


def parse_mode1(text):
    out = {}
    for m in re.finditer(r"source_slots=(\d+).*?cold_median_ms=([\d.]+).*?append_median_ms=([\d.]+)", text):
        n, cold, app = m.group(1), float(m.group(2)), float(m.group(3))
        out[f"cold@{n}"] = cold
        out[f"append@{n}"] = app
    return out


def parse_streaming(text):
    out = {}
    for line in text.splitlines():
        m = re.match(r"^(\s*)([a-z_0-9]+)\s+median_ms=\s*([\d.]+)\s*$", line)
        if not m:
            continue
        indent, name, value = len(m.group(1)), m.group(2), float(m.group(3))
        if indent == 2:
            out[name] = value
        elif indent == 4:
            out[f"stage_{name}"] = value
        elif indent == 6:
            out[f"page_{name}"] = value
    return out


def parse_activity(text):
    out = {}
    for m in re.finditer(r"turns=(\d+) messages=(\d+) edit_stats_median_ms=([\d.]+) running_ids_median_ms=([\d.]+) activity_init_median_ms=([\d.]+)", text):
        msgs = m.group(2)
        out[f"edit_stats@{msgs}"] = float(m.group(3))
        out[f"running_ids@{msgs}"] = float(m.group(4))
        out[f"activity_init@{msgs}"] = float(m.group(5))
    for m in re.finditer(r"single_turn_calls=(\d+) messages=(\d+) activity_init_median_ms=([\d.]+)", text):
        out[f"single_turn_activity@{m.group(2)}"] = float(m.group(3))
    return out


def parse_edit_lines(text):
    d = json.loads(text)
    out = {}
    for r in d["results"]:
        if r["source_rows"] in (64, 512):
            out[f"edit{r['source_rows']}_{r['case']}"] = r["median_ms"]
    return out


def parse_token(text):
    d = json.loads(text)
    out = {}
    for r in d["results"]:
        ft = r["fixture_turns"]
        fields = {}
        for sample in r["samples"]:
            for k, v in sample.items():
                if k.endswith("_ms"):
                    fields.setdefault(k, []).append(v)
        for k, values in fields.items():
            out[f"token{ft}_{k}"] = statistics.median(values)
    return out


PARSERS = {"1": parse_mode1, "streaming": parse_streaming, "activity": parse_activity,
           "edit-lines": parse_edit_lines, "presentation-token": parse_token}


def collect(pair_dir):
    data = {}  # metric -> {pair -> {variant -> value}}
    for path in sorted(pathlib.Path(pair_dir).glob("pair*-*.log")):
        m = re.match(r"pair(\d+)-(baseline|candidate)-(.+)\.log$", path.name)
        if not m:
            continue
        pair, variant, mode = int(m.group(1)), m.group(2), m.group(3)
        if mode not in PARSERS:
            continue
        try:
            parsed = PARSERS[mode](path.read_text())
        except Exception as e:
            raise SystemExit(f"parse failure {path}: {e}")
        for metric, value in parsed.items():
            data.setdefault(metric, {}).setdefault(pair, {})[variant] = value
    return data


def stats(b, c):
    bm, cm = statistics.median(b), statistics.median(c)
    p = [(ci - bi) / bi * 100 for bi, ci in zip(b, c)]
    spread = max((max(b) - min(b)) / min(b) * 100 if min(b) > 0 else 0.0,
                 (max(c) - min(c)) / min(c) * 100 if min(c) > 0 else 0.0)
    return {"baseline_median": bm, "candidate_median": cm,
            "change_percent": (cm - bm) / bm * 100 if bm else float("nan"),
            "worst_pair_percent": max(p), "max_spread_percent": spread,
            "baseline_samples": b, "candidate_samples": c}


def main():
    pair_dir, out_path = sys.argv[1], sys.argv[2]
    data = collect(pair_dir)
    summary = {}
    for metric, pairs in sorted(data.items()):
        full = {p: v for p, v in sorted(pairs.items()) if len(v) == 2}
        if len(full) != 6:
            raise SystemExit(f"metric {metric}: expected 6 complete pairs, got {len(full)}")
        b = [v["baseline"] for v in full.values()]
        c = [v["candidate"] for v in full.values()]
        if max(b) == 0 and max(c) == 0:
            continue  # print-grid zero on both sides
        summary[metric] = stats(b, c)
    positives = sorted((k, round(v["change_percent"], 2)) for k, v in summary.items()
                       if round(v["change_percent"], 2) > round(v["max_spread_percent"], 2)
                       and round(v["worst_pair_percent"], 2) > 0)
    pathlib.Path(out_path).write_text(json.dumps(summary, indent=1, sort_keys=True) + "\n")
    print(f"{out_path}: {len(summary)} metrics; positives_beyond_spread: {positives or 'NONE'}")


if __name__ == "__main__":
    main()
