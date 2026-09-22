#!/usr/bin/env python3
"""Attribute Instruments update/frame records to the app and its HistoryScroll span.

Never use compositor-wide frame counts as app FPS. Empty/uncorrelated captures fail.
"""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET


def table(path):
    root = ET.parse(path).getroot()
    refs = {node.attrib["id"]: node for node in root.iter() if "id" in node.attrib}

    def resolve(node):
        while "ref" in node.attrib:
            node = refs[node.attrib["ref"]]
        return node

    def value(node):
        node = resolve(node)
        if node.tag == "process":
            return resolve(node.find("pid")).text
        return (node.text or "").strip() or node.attrib.get("fmt", "")

    columns = [node.findtext("mnemonic") for node in root.find(".//schema").findall("col")]
    seen, rows = set(), []
    for row in root.findall(".//row"):
        values = tuple(value(cell) for cell in row)
        # Points of Interest can export the same signpost through two tables.
        if values not in seen:
            seen.add(values)
            rows.append(dict(zip(columns, values)))
    return rows


def intervals(rows, pid, name):
    opened, spans = {}, []
    for row in sorted(rows, key=lambda item: int(item["time"])):
        if row["process"] != pid or row["name"] != name or row["subsystem"] != "dev.perch.nativeacceptance":
            continue
        key = row["identifier"]
        if row["event-type"] == "Begin":
            if key in opened:
                raise ValueError("overlapping signpost IDs")
            opened[key] = int(row["time"])
        elif row["event-type"] == "End":
            spans.append((opened.pop(key), int(row["time"])))
    if opened:
        raise ValueError("unclosed signpost interval")
    return spans


def stats(values):
    ordered = sorted(values)
    return {"count": len(ordered), "median_ms": ordered[len(ordered) // 2],
            "p95_ms": ordered[int((len(ordered) - 1) * .95)], "max_ms": ordered[-1]} if ordered else {"count": 0}


def summarize(folder):
    toc = ET.parse(folder / "toc.xml")
    pid = toc.find(".//info/target/process").attrib["pid"]
    signs = table(folder / "os-signpost.xml")
    spans = intervals(signs, pid, "HistoryScroll")
    if len(spans) != 1:
        raise ValueError("requires exactly one complete HistoryScroll interval")
    begin, end = spans[0]
    if end <= begin:
        raise ValueError("invalid activity interval")

    def active(row):
        return row["process"] == pid and begin <= int(row["start"]) < end

    updates = [row for row in table(folder / "hitches-updates.xml") if active(row)]
    hitches = [row for row in table(folder / "hitches.xml") if active(row)]
    # Join on the actual frame identity, not nearby timestamps or a global FPS.
    key = lambda row: (row["display"], row["swap-id"], row["surface-id"])
    lifetimes = {key(row): row for row in table(folder / "hitches-frame-lifetimes.xml")}
    frames = {key(row): lifetimes[key(row)] for row in updates if key(row) in lifetimes}
    if not updates or not frames:
        raise ValueError("no app-owned updates joined to displayed frame lifetimes")
    stalls = intervals(signs, pid, "IntentionalStall")
    # A positive control validates that the detector sees a known main-thread
    # stop. Absence of a report must not silently become '0 hitches, passed'.
    overlapping = [row for row in hitches if any(
        int(row["start"]) < stop and int(row["start"]) + int(row["duration"]) > start
        for start, stop in stalls)]
    frame_ends = sorted({int(row["start"]) + int(row["duration"]) for row in frames.values()})
    control_gaps = [(right - left) / 1e6 for left, right in zip(frame_ends, frame_ends[1:])
                    if any(left <= start and right >= stop for start, stop in stalls)]
    return {
        "status": "usable_frame_events", "target_pid": int(pid),
        "activity_start_ns": begin, "activity_end_ns": end, "activity_seconds": (end - begin) / 1e9,
        "update_duration": stats([int(row["duration"]) / 1e6 for row in updates]),
        "joined_frame_lifetime": stats([int(row["duration"]) / 1e6 for row in frames.values()]),
        "unmatched_update_count": sum(key(row) not in lifetimes for row in updates),
        "detected_app_hitches": len(hitches),
        "hitch_duration_ms": sum(int(row["duration"]) for row in hitches) / 1e6,
        "positive_control_spans": len(stalls), "positive_control_detected": bool(stalls and overlapping),
        "frame_lifetime_end_gap_covering_control_ms": control_gaps,
        "note": "Durations are Instruments update/frame lifetime records, not screen refresh intervals. Zero detected hitches in a short run does not establish smoothness; the detector needs a separate positive control.",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        result = summarize(args.directory)
    except (OSError, ValueError, KeyError, AttributeError, ET.ParseError) as error:
        print(json.dumps({"status": "unverified", "error": str(error)}, indent=2))
        raise SystemExit(1)
    print(json.dumps(result, indent=2))
