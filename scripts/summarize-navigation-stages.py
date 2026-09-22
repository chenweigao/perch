#!/usr/bin/env python3
"""Associate native reading steps with host creation; compare idle/scroll search.

Usage: summarize-navigation-stages.py READING_DIR ROUNDTRIP_DIR
Input directories come from run-navigation-check.py. Nested stage times overlap.
"""
from collections import defaultdict
import json
from pathlib import Path
import sys


def statistics(values):
    ordered = sorted(values)
    if not ordered:
        return {"count": 0}
    return {"count": len(ordered), "median_ms": ordered[len(ordered) // 2],
            "p95_ms": ordered[int((len(ordered) - 1) * .95)], "max_ms": ordered[-1]}


def totals(stages):
    result = defaultdict(lambda: {"count": 0, "ms": 0})
    for sample in stages:
        for key, value in sample.items():
            result[key]["count"] += value["count"]
            result[key]["ms"] += value["ms"]
    return dict(result)


def reading_steps(times, stages):
    assert len(times) == len(stages)
    return {
        "with_host_creation": statistics([t for t, s in zip(times, stages)
                                          if s.get("host_create", {}).get("count", 0)]),
        "without_host_creation": statistics([t for t, s in zip(times, stages)
                                             if not s.get("host_create", {}).get("count", 0)]),
        "nested_stage_totals": totals(stages),
    }


reading_dir, roundtrip_dir = map(Path, sys.argv[1:])
reading = json.loads((reading_dir / "result.json").read_text())
trace = json.loads((reading_dir / "reading-trace.json").read_text())
roundtrip = json.loads((roundtrip_dir / "result.json").read_text())
assert reading["status"] == roundtrip["status"] == "passed"
assert reading["build"] == roundtrip["build"]
print(json.dumps({
    "build": reading["build"], "history_turns": reading["history_turns"],
    "downward": reading_steps([s["elapsed_ms"] for s in trace], [s["render_stages"] for s in trace]),
    "upward": reading_steps(reading["upward_reading_samples_ms"], reading["upward_render_stages"]),
    "max_retained_hosts": max(s["retained"] for s in reading["upward_host_counts"]),
    "max_mounted_hosts": max(s["mounted"] for s in reading["upward_host_counts"]),
    "reading_resident_mb": {k: v for k, v in reading.items() if k.startswith("resident_mb_")},
    "roundtrip": {k: v for k, v in roundtrip.items()
                  if k.endswith("_ms") or k.startswith("resident_mb_") or k == "dropped_keystrokes"},
    "idle_search_nested_stages": totals(roundtrip["search_without_scroll_render_stages"]),
    "scroll_search_nested_stages": totals(roundtrip["search_during_scroll_render_stages"]),
    "note": "Step association, not causal speedup. Stage durations overlap. Search runs idle first, then scrolling; fixture scope is not the production search sheet. Times are application work, not display frames.",
}, indent=2))
