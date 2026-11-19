import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

import numpy


CONTRACT_SHA256 = "e376d105d4c7df452ce9df01bd416e032a1a23b373f7c0c70ebafa663a079cd9"
READER_SHA256 = "9d4e7eeba751edccac29645cf7099bdafa3b53d54952f2bc6d62a365134b1237"
HEADER = [544, 48, 1112, 104]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_contract(directory):
    frozen = directory / "frozen-contract.json"
    if digest(frozen) != CONTRACT_SHA256:
        raise ValueError("Frozen contract hash mismatch")
    contract = json.loads(frozen.read_text())
    bound_files = {
        "expected_list_sha256": directory.parent / "expected-differences.md",
        "allowed_regions_sha256": directory.parent / "allowed-regions-before.json",
        "capture_wrapper_sha256": directory / "capture-matrix.py",
        "existing_capture_driver_sha256": directory.parents[4] / "scripts/capture-style-loop.py",
    }
    for field, source in bound_files.items():
        if digest(source) != contract[field]:
            raise ValueError(f"Frozen input hash mismatch: {field}")
    regions = json.loads(bound_files["allowed_regions_sha256"].read_text())
    scenes = set(contract["scenes"])
    affected = set(contract["affected_scenes"])
    if len(scenes) != 27 or len(affected) != 9 or affected != set(regions["scenarios"]):
        raise ValueError("Frozen scene coverage mismatch")
    if affected != {scene for scene in scenes if scene.startswith("workbench-")}:
        raise ValueError("Only existing Workbench header scenes may change")
    if any(region != HEADER for region in regions["scenarios"].values()):
        raise ValueError("Unexpected header-region expansion")
    if regions["baseline_head"] != contract["baseline_head"] or regions["reference_geometry"] != [1120, 820]:
        raise ValueError("Frozen baseline or geometry mismatch")
    if contract["scene_count"] != 27 or contract["expected_repeat_pairs"] != 27 or contract["expected_raw_png_per_matrix"] != 54:
        raise ValueError("Frozen matrix dimensions mismatch")
    return contract, regions["scenarios"]


def load_reader(directory):
    source = directory.parents[1] / "round-3/contracts/compare-captures.py"
    if digest(source) != READER_SHA256:
        raise ValueError("Protected round 3 PNG reader hash mismatch")
    specification = importlib.util.spec_from_file_location("protected_style_png_reader", source)
    if specification is None or specification.loader is None:
        raise ValueError("Unable to load the protected PNG reader")
    reader = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(reader)
    return reader


def read_matrix(root, expected_head, contract, reader):
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest["status"] != "passed" or manifest["commit"] != expected_head or manifest["dirty"] is not False:
        raise ValueError("Unpassed, dirty or wrong-source matrix")
    scenes = set(contract["scenes"])
    entries = {entry["group"]: entry for entry in manifest["comparisons"]}
    if len(manifest["comparisons"]) != 27 or set(entries) != scenes:
        raise ValueError("Matrix must contain exactly the frozen 27 scenes")
    expected_paths = {f"{scene}/repeat-{repeat}/capture.png" for scene in scenes for repeat in (1, 2)}
    actual_paths = {str(source.relative_to(root)) for source in root.rglob("*.png")}
    if actual_paths != expected_paths:
        raise ValueError("Matrix must contain exactly 54 original PNGs")
    commands = {entry["name"]: entry for entry in manifest["commands"]}
    if len(commands) != len(manifest["commands"]):
        raise ValueError("Duplicate capture command")
    captures = {}
    for name, entry in sorted(entries.items()):
        repeats = []
        hashes = []
        if entry["first_exists"] is not True or entry["second_exists"] is not True:
            raise ValueError(f"Manifest missing-repeat claim: {name}")
        for repeat, hash_key in ((1, "first_sha256"), (2, "second_sha256")):
            folder = root / name / f"repeat-{repeat}"
            source = folder / "capture.png"
            actual_hash = digest(source)
            if actual_hash != entry[hash_key]:
                raise ValueError(f"PNG hash mismatch: {name} repeat {repeat}")
            hashes.append(actual_hash)
            metadata = json.loads((folder / "window.json").read_text())
            ready = json.loads((folder / "capture.png.ready.json").read_text())
            if metadata != ready or type(metadata["window_number"]) is not int or metadata["window_number"] <= 0:
                raise ValueError(f"Readiness metadata mismatch: {name} repeat {repeat}")
            expected_dark = name.endswith("-dark")
            if metadata["dark"] != expected_dark or metadata["effective_dark"] != expected_dark:
                raise ValueError(f"Effective appearance mismatch: {name}")
            if metadata["large_type"] != ("large-type" in name):
                raise ValueError(f"Type-size fixture mismatch: {name}")
            if metadata["locale"] != ("en" if "english" in name else "zh-Hans"):
                raise ValueError(f"Language fixture mismatch: {name}")
            command = commands[f"{name}-repeat-{repeat}"]
            screenshot = commands[f"{name}-repeat-{repeat}-screencapture"]
            screenshot_arguments = screenshot["command"]
            if screenshot["exit_code"] != 0 or "-l" not in screenshot_arguments:
                raise ValueError(f"Unpassed screencapture command: {name} repeat {repeat}")
            window_argument = screenshot_arguments.index("-l") + 1
            if screenshot_arguments[window_argument] != str(metadata["window_number"]):
                raise ValueError(f"Wrong captured window: {name} repeat {repeat}")
            environment = {key: value for key, value in command["environment"].items() if key != "PERCH_STYLE_CAPTURE"}
            visible, rgba = reader.read_capture(source)
            height, width = rgba.shape[:2]
            if entry["dimensions"] != [width, height]:
                raise ValueError(f"Manifest PNG dimensions mismatch: {name}")
            if name in contract["affected_scenes"] and ([width, height] != [1120, 820] or metadata["backing_scale"] != 1):
                raise ValueError(f"Frozen header geometry mismatch: {name}")
            repeats.append({"metadata": metadata, "environment": environment, "visible": visible, "rgba": rgba})
        for field in reader.METADATA:
            if repeats[0]["metadata"][field] != repeats[1]["metadata"][field]:
                raise ValueError(f"Repeat camera/fixture drift: {name}/{field}")
        if repeats[0]["environment"] != repeats[1]["environment"]:
            raise ValueError(f"Repeat environment drift: {name}")
        if hashes[0] != hashes[1] or entry["byte_identical"] is not True or entry["identical"] is not True:
            raise ValueError(f"Unstable PNG-byte repeat: {name}")
        if not numpy.array_equal(repeats[0]["rgba"], repeats[1]["rgba"]) or not numpy.array_equal(repeats[0]["visible"], repeats[1]["visible"]):
            raise ValueError(f"Unstable decoded repeat: {name}")
        captures[name] = repeats[0]
    return captures


def bounds(mask):
    coordinates = numpy.argwhere(mask)
    if not coordinates.size:
        return None
    return [int(coordinates[:, 1].min()), int(coordinates[:, 0].min()),
            int(coordinates[:, 1].max()) + 1, int(coordinates[:, 0].max()) + 1]


def compare(before, after, mode, regions, reader):
    if set(before) != set(after):
        raise ValueError("Cross-matrix scene mismatch")
    results = []
    for name in sorted(before):
        first, second = before[name], after[name]
        for field in reader.METADATA:
            if first["metadata"][field] != second["metadata"][field]:
                raise ValueError(f"Cross-matrix camera/fixture drift: {name}/{field}")
        if first["environment"] != second["environment"] or first["rgba"].shape != second["rgba"].shape:
            raise ValueError(f"Cross-matrix fixture/dimensions mismatch: {name}")
        height, width = first["rgba"].shape[:2]
        allowed = [regions[name]] if mode == "header" and name in regions else []
        changed_visible = numpy.any(first["visible"] != second["visible"], axis=2)
        changed_rgba = numpy.any(first["rgba"] != second["rgba"], axis=2)
        outside_visible = changed_visible.copy()
        outside_rgba = changed_rgba.copy()
        for left, top, right, bottom in allowed:
            outside_visible[top:bottom, left:right] = False
            outside_rgba[top:bottom, left:right] = False
        results.append({
            "group": name, "dimensions": [width, height], "allowed_regions": allowed,
            "changed_visible_pixels": int(changed_visible.sum()), "changed_rgba_pixels": int(changed_rgba.sum()),
            "outside_allowed_visible_pixels": int(outside_visible.sum()), "outside_allowed_rgba_pixels": int(outside_rgba.sum()),
            "changed_visible_bbox": bounds(changed_visible), "changed_rgba_bbox": bounds(changed_rgba),
            "pass": not bool(outside_visible.any() or outside_rgba.any()),
        })
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path)
    parser.add_argument("--before-head", required=True)
    parser.add_argument("--after-head")
    parser.add_argument("--mode", choices=("baseline", "header", "stability"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    report = {"status": "failed", "mode": arguments.mode, "before_head": arguments.before_head,
              "after_head": arguments.after_head, "tolerance": 0, "frozen_contract_sha256": CONTRACT_SHA256,
              "png_reader_sha256": READER_SHA256}
    try:
        directory = Path(__file__).resolve().parent
        contract, regions = load_contract(directory)
        reader = load_reader(directory)
        if arguments.mode in ("baseline", "header") and arguments.before_head != contract["baseline_head"]:
            raise ValueError("Wrong frozen baseline head")
        first = read_matrix(arguments.before, arguments.before_head, contract, reader)
        report.update({"before_repeat_pixel_pairs": 27, "before_repeat_byte_pairs": 27, "before_original_pngs": 54})
        if arguments.mode == "baseline":
            if arguments.after is not None or arguments.after_head is not None:
                raise ValueError("Baseline verification does not accept an after matrix")
            report["status"] = "passed"
        else:
            if arguments.after is None or arguments.after_head is None:
                raise ValueError("Cross-matrix verification requires an after matrix and exact head")
            if arguments.mode == "stability" and arguments.before_head != arguments.after_head:
                raise ValueError("Cross-job stability requires exactly the same source head")
            second = read_matrix(arguments.after, arguments.after_head, contract, reader)
            results = compare(first, second, arguments.mode, regions, reader)
            report.update({"after_repeat_pixel_pairs": 27, "after_repeat_byte_pairs": 27, "after_original_pngs": 54,
                           "groups": results, "unexpected_groups": [result["group"] for result in results if not result["pass"]]})
            report["status"] = "passed" if not report["unexpected_groups"] else "failed"
    except Exception as error:
        report["error"] = str(error)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "mode": arguments.mode, "groups": len(report.get("groups", [])),
                      "unexpected_groups": report.get("unexpected_groups", []), "error": report.get("error")}, ensure_ascii=False))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
