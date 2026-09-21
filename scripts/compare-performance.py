#!/usr/bin/env python3
"""Compare two compatible local rendering reports without selecting best trials."""
import json
import statistics
import sys

if len(sys.argv) != 3:
    raise SystemExit("Usage: scripts/compare-performance.py baseline.json current.json")
with open(sys.argv[1]) as file:
    baseline = json.load(file)
with open(sys.argv[2]) as file:
    current = json.load(file)
for key in ("workload_version", "workload_sha256", "history_turns", "events_per_trial", "window_width", "window_height", "display_scale"):
    if baseline[key] != current[key]:
        raise SystemExit(f"Incomparable reports: {key} differs")
for key in ("fixture_sha256", "package_resolved_sha256", "compiler", "macos"):
    if baseline["metadata"][key] != current["metadata"][key]:
        raise SystemExit(f"Incomparable reports: metadata.{key} differs")
if baseline["metadata"]["variant"] != "baseline" or current["metadata"]["variant"] != "current":
    raise SystemExit("Expected baseline report followed by current report")
if baseline.get("scenario", "assistant") != current.get("scenario", "assistant"):
    raise SystemExit("Incomparable reports: assistant and thinking scenarios differ")
if baseline["workload_version"] == "transcript-pipeline-v2":
    for key in ("reading_width", "content_viewport_height"):
        if baseline[key] != current[key]:
            raise SystemExit(f"Incomparable reports: {key} differs")
ratio = current["aggregate_events_per_second"] / baseline["aggregate_events_per_second"]
result = {"scope": baseline["scope"], "scenario": baseline.get("scenario", "assistant"), "throughput_ratio": ratio, "target_3x_met": ratio >= 3}
for name, report in (("baseline", baseline), ("current", current)):
    times = sorted(value for trial in report["trials"] for value in trial["event_ms"])
    result[name] = {
        "events_per_second": report["aggregate_events_per_second"],
        "total_wall_seconds": report["total_wall_seconds"],
        "median_event_ms": statistics.median(times),
        "p95_event_ms": times[int((len(times) - 1) * 0.95)],
        "trials": len(report["trials"]),
        "source_sha256": report["metadata"]["source_sha256"],
        "reading_width": report.get("reading_width"),
        "content_viewport_width": report.get("content_viewport_width"),
        "content_viewport_height": report.get("content_viewport_height"),
    }
print(json.dumps(result, indent=2, ensure_ascii=False))
