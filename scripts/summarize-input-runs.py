#!/usr/bin/env python3
"""Aggregate repeated unprofiled mounted-input runs; never mix captures or controls."""
import argparse
import json
from pathlib import Path
from statistics import median


def summarize(folders):
    folders = [Path(folder).resolve() for folder in folders]
    if len(set(folders)) != len(folders):
        raise ValueError("Each repetition must be a different run directory")
    groups = {}
    identity = None
    for folder in folders:
        manifest = json.loads((folder / "manifest.json").read_text())
        result = json.loads((folder / "result.json").read_text())
        if (manifest["capture"] != "none" or manifest.get("input_positive_control")
                or result.get("input_positive_control") or manifest["exit_code"] != 0
                or not manifest["behavior_passed"] or result["status"] != "passed"):
            raise ValueError("Only successful unprofiled non-control runs can be combined")
        mode = result["mode"]
        if mode not in ("input", "kimi-input") or mode != manifest["mode"]:
            raise ValueError("Expected an input or kimi-input run")
        current = {key: manifest[key] for key in ["source_sha256", "binary_sha256", "compiler", "window_points"]}
        if identity is not None and identity != current:
            raise ValueError("Runs must use the same source, binary, compiler and window")
        identity = current
        groups.setdefault(mode, []).append((folder, result))
    if not groups or any(len(runs) < 3 for runs in groups.values()):
        raise ValueError("At least three distinct repetitions are required per provider")
    output = {}
    for mode, runs in groups.items():
        metrics = {}
        for metric in runs[0][1]["input_metrics"]:
            values = [result["input_metrics"][metric] for _, result in runs]
            medians = [value["median"] for value in values]
            p95s = [value["p95"] for value in values]
            metrics[metric] = {"median_of_run_medians_ms": median(medians),
                               "run_median_range_ms": [min(medians), max(medians)],
                               "run_p95_range_ms": [min(p95s), max(p95s)]}
        output[mode] = {"runs": [folder.name for folder, _ in runs], "metrics": metrics,
            "composition_cycles": sum(result["input_composition_cycles"] for _, result in runs),
            "maximum_anchor_drift_points": max(result["input_max_anchor_drift_points"] for _, result in runs),
            "input_reader_evaluations": sum(sample["plain_reader_evaluations"] + sample["commit_reader_evaluations"]
                                             for _, result in runs for sample in result["input_samples"])}
    return {"identity": identity, "providers": output,
            "boundary": "Mounted AppKit input methods to production delegate/layout flush; includes readiness waits. No hardware/real IME candidate/display latency or FPS. Report per-run variation; samples are not independent users."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directories", nargs="+", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.directories), ensure_ascii=False, indent=2))
