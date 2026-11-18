import argparse
import hashlib
import json
from pathlib import Path

import numpy
from PIL import Image


SCENES = {
    "main-light", "main-dark", "main-english", "main-large-type",
    "main-english-dark", "main-english-large-type", "main-english-large-type-dark",
    "main-large-type-dark", "main-find", "main-find-dark", "main-inspector-closed",
    "main-dashboard", "main-scroll", "workbench-light", "workbench-dark", "workbench-english",
    "workbench-empty-light", "sidebar-light", "sidebar-dark", "sidebar-english",
    "composer-light", "composer-dark",
}
METADATA = (
    "window_frame", "content_bounds", "backing_scale", "appearance", "dark",
    "effective_dark", "locale", "large_type",
)
COMPOSER = {"composer-light", "composer-dark"}


def read_capture(path):
    with Image.open(path) as image:
        image.verify()
    with Image.open(path) as image:
        rgba = numpy.array(image.convert("RGBA"), dtype=numpy.uint32)
    alpha = rgba[:, :, 3:4]
    visible = ((rgba[:, :, :3] * alpha + 255 * (255 - alpha) + 127) // 255).astype(numpy.int16)
    return visible, rgba


def read_matrix(root, expected_head):
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest["status"] != "passed" or manifest["commit"] != expected_head:
        raise ValueError(f"Unpassed or wrong-source matrix: {root}")
    entries = {entry["group"]: entry for entry in manifest["comparisons"]}
    if len(manifest["comparisons"]) != 22 or set(entries) != SCENES:
        raise ValueError("Matrix must contain exactly the original 22 scenes")
    commands = {entry["name"]: entry for entry in manifest["commands"]}
    captures = {}
    byte_identical = 0
    for name, entry in sorted(entries.items()):
        repeats = []
        for repeat, hash_key in ((1, "first_sha256"), (2, "second_sha256")):
            folder = root / name / f"repeat-{repeat}"
            path = folder / "capture.png"
            if hashlib.sha256(path.read_bytes()).hexdigest() != entry[hash_key]:
                raise ValueError(f"PNG hash mismatch: {name} repeat {repeat}")
            metadata = json.loads((folder / "window.json").read_text())
            ready = json.loads((folder / "capture.png.ready.json").read_text())
            if metadata != ready or not isinstance(metadata["window_number"], int) or metadata["window_number"] <= 0:
                raise ValueError(f"Readiness metadata mismatch: {name} repeat {repeat}")
            expected_dark = name.endswith("-dark")
            if metadata["dark"] != expected_dark or metadata["effective_dark"] != expected_dark:
                raise ValueError(f"Effective appearance mismatch: {name}")
            if metadata["large_type"] != ("large-type" in name):
                raise ValueError(f"Type-size fixture mismatch: {name}")
            if metadata["locale"] != ("en" if "english" in name else "zh-Hans"):
                raise ValueError(f"Language fixture mismatch: {name}")
            command = commands[f"{name}-repeat-{repeat}"]
            environment = {key: value for key, value in command["environment"].items() if key != "PERCH_STYLE_CAPTURE"}
            visible, rgba = read_capture(path)
            repeats.append({"metadata": metadata, "environment": environment, "visible": visible, "rgba": rgba})
        for field in METADATA:
            if repeats[0]["metadata"][field] != repeats[1]["metadata"][field]:
                raise ValueError(f"Repeat camera/fixture drift: {name}/{field}")
        if repeats[0]["environment"] != repeats[1]["environment"] or not numpy.array_equal(repeats[0]["visible"], repeats[1]["visible"]):
            raise ValueError(f"Unstable repeat: {name}")
        actual_bytes_equal = entry["first_sha256"] == entry["second_sha256"]
        if actual_bytes_equal != entry["byte_identical"] or entry["identical"] is not True:
            raise ValueError(f"Manifest repeat claim mismatch: {name}")
        byte_identical += int(actual_bytes_equal)
        captures[name] = repeats[0]
    return captures, byte_identical


def compare(before, after, mode, allowed):
    if mode == "repair":
        if set(allowed) != SCENES:
            raise ValueError("Repair regions must be fixed for every scene")
    elif allowed:
        raise ValueError("Cross-job stability allows no changed region")
    results = []
    for name in sorted(SCENES):
        first, second = before[name], after[name]
        for field in METADATA:
            if first["metadata"][field] != second["metadata"][field]:
                raise ValueError(f"Cross-matrix camera/fixture drift: {name}/{field}")
        if first["environment"] != second["environment"] or first["visible"].shape != second["visible"].shape:
            raise ValueError(f"Cross-matrix fixture/dimensions mismatch: {name}")
        height, width = first["visible"].shape[:2]
        regions = allowed[name] if mode == "repair" else []
        expected_regions = [[0, 0, width, height]] if name in COMPOSER and mode == "repair" else []
        if regions != expected_regions:
            raise ValueError(f"Unexpected repair-region expansion: {name}")
        changed = numpy.any(first["visible"] != second["visible"], axis=2)
        outside = changed.copy()
        for left, top, right, bottom in regions:
            outside[top:bottom, left:right] = False
        coordinates = numpy.argwhere(changed)
        bounds = None if not coordinates.size else [int(coordinates[:, 1].min()), int(coordinates[:, 0].min()), int(coordinates[:, 1].max()) + 1, int(coordinates[:, 0].max()) + 1]
        result = {
            "group": name, "dimensions": [width, height], "changed_visible_pixels": int(changed.sum()),
            "outside_allowed_pixels": int(outside.sum()), "changed_bbox": bounds,
            "allowed_regions": regions, "pass": not bool(outside.any()),
        }
        if name in COMPOSER:
            result["before_center_rgba"] = first["rgba"][height // 2, width // 2].astype(int).tolist()
            result["after_center_rgba"] = second["rgba"][height // 2, width // 2].astype(int).tolist()
        results.append(result)
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--before-head", required=True)
    parser.add_argument("--after-head", required=True)
    parser.add_argument("--mode", choices=("repair", "stability"), required=True)
    parser.add_argument("--allowed", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {"status": "failed", "mode": args.mode, "before_head": args.before_head, "after_head": args.after_head, "tolerance": 0}
    try:
        if args.mode == "stability" and args.before_head != args.after_head:
            raise ValueError("Cross-job stability requires exactly the same source head")
        first, first_bytes = read_matrix(args.before, args.before_head)
        second, second_bytes = read_matrix(args.after, args.after_head)
        allowed = json.loads(args.allowed.read_text()) if args.allowed else {}
        results = compare(first, second, args.mode, allowed)
        report.update({"before_repeat_pixel_pairs": 22, "after_repeat_pixel_pairs": 22,
                       "before_repeat_byte_pairs": first_bytes, "after_repeat_byte_pairs": second_bytes,
                       "groups": results, "unexpected_groups": [result["group"] for result in results if not result["pass"]]})
        report["status"] = "passed" if not report["unexpected_groups"] else "failed"
    except Exception as error:
        report["error"] = str(error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "mode": args.mode, "groups": len(report.get("groups", [])), "unexpected_groups": report.get("unexpected_groups", []), "error": report.get("error")}, ensure_ascii=False))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
