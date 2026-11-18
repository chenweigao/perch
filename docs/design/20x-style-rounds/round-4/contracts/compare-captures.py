import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re

import numpy


HEADER_REGION = [1218, 44, 1530, 96]
HEADER_SCENES = {
    "main-light", "main-dark", "main-english", "main-large-type",
    "main-english-dark", "main-english-large-type", "main-english-large-type-dark",
    "main-large-type-dark", "main-find", "main-find-dark", "main-scroll",
}
EXPECTED_SHA256 = "8bc899da4c896f1cdc8a99520dbba081955dd5b6f10a3d84641c04841e5b7be4"
REGIONS_SHA256 = "3002366930e124e2e335abd1d97730115b3dac31a7506f771087a36faafeb115"


def load_reader():
    source = Path(__file__).resolve().parents[2] / "round-3/contracts/compare-captures.py"
    specification = importlib.util.spec_from_file_location("style_round_3_matrix_reader", source)
    if specification is None or specification.loader is None:
        raise ValueError("Unable to load the archived matrix reader")
    reader = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(reader)
    return reader, hashlib.sha256(source.read_bytes()).hexdigest()


def validate_contract(arguments):
    for revision in (arguments.before_head, arguments.after_head):
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ValueError("Expected an exact source revision")
    if hashlib.sha256(arguments.expected_list.read_bytes()).hexdigest() != EXPECTED_SHA256:
        raise ValueError("The prewritten expected differences changed")
    if arguments.mode == "stability":
        if arguments.before_head != arguments.after_head or arguments.allowed is not None:
            raise ValueError("Stability requires the same source and no allowed region")
        return {}
    if arguments.allowed is None or hashlib.sha256(arguments.allowed.read_bytes()).hexdigest() != REGIONS_SHA256:
        raise ValueError("The frozen header regions changed or are missing")
    contract = json.loads(arguments.allowed.read_text())
    regions = contract["scenarios"]
    if contract["baseline_head"] != arguments.before_head or contract["reference_geometry"] != [1536, 900]:
        raise ValueError("The header contract does not match the actual before source/geometry")
    if set(regions) != HEADER_SCENES or any(region != HEADER_REGION for region in regions.values()):
        raise ValueError("The header region or its scene scope expanded")
    return regions


def read_matrix(reader, directory, revision):
    manifest = json.loads((directory / "manifest.json").read_text())
    if manifest["dirty"] is not False:
        raise ValueError("The actual capture checkout must be clean")
    captures, byte_pairs = reader.read_matrix(directory, revision)
    if byte_pairs != 22:
        raise ValueError("All 22 repeat pairs must be byte-identical, not merely approximate pixels")
    return captures, byte_pairs


def bounds(changed):
    coordinates = numpy.argwhere(changed)
    if not coordinates.size:
        return None
    return [int(coordinates[:, 1].min()), int(coordinates[:, 0].min()),
            int(coordinates[:, 1].max()) + 1, int(coordinates[:, 0].max()) + 1]


def compare_matrices(reader, before, after, regions):
    results = []
    for scene in sorted(reader.SCENES):
        first, second = before[scene], after[scene]
        for field in reader.METADATA:
            if first["metadata"][field] != second["metadata"][field]:
                raise ValueError(f"Cross-matrix camera/fixture drift: {scene}/{field}")
        if first["environment"] != second["environment"]:
            raise ValueError(f"Cross-matrix environment drift: {scene}")
        if first["rgba"].shape != second["rgba"].shape or first["visible"].shape != second["visible"].shape:
            raise ValueError(f"Cross-matrix dimensions changed: {scene}")
        height, width = first["rgba"].shape[:2]
        region = regions.get(scene)
        if region is not None and ([width, height] != [1536, 900] or first["metadata"]["backing_scale"] != 1):
            raise ValueError(f"Unverified header capture geometry: {scene}")
        visible_changed = numpy.any(first["visible"] != second["visible"], axis=2)
        rgba_changed = numpy.any(first["rgba"] != second["rgba"], axis=2)
        outside_visible = visible_changed.copy()
        outside_rgba = rgba_changed.copy()
        if region is not None:
            left, top, right, bottom = region
            outside_visible[top:bottom, left:right] = False
            outside_rgba[top:bottom, left:right] = False
        results.append({
            "group": scene, "dimensions": [width, height], "allowed_region": region,
            "changed_visible_pixels": int(visible_changed.sum()), "changed_rgba_pixels": int(rgba_changed.sum()),
            "changed_visible_bbox": bounds(visible_changed), "changed_rgba_bbox": bounds(rgba_changed),
            "outside_allowed_visible_pixels": int(outside_visible.sum()),
            "outside_allowed_rgba_pixels": int(outside_rgba.sum()),
            "pass": not bool(outside_visible.any() or outside_rgba.any()),
        })
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--before-head", required=True)
    parser.add_argument("--after-head", required=True)
    parser.add_argument("--mode", choices=("header", "stability"), required=True)
    parser.add_argument("--expected-list", type=Path, required=True)
    parser.add_argument("--allowed", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    report = {"status": "failed", "mode": arguments.mode, "before_head": arguments.before_head,
              "after_head": arguments.after_head, "tolerance": 0, "expected_list_sha256": EXPECTED_SHA256}
    try:
        regions = validate_contract(arguments)
        reader, reader_digest = load_reader()
        before, before_pairs = read_matrix(reader, arguments.before, arguments.before_head)
        after, after_pairs = read_matrix(reader, arguments.after, arguments.after_head)
        results = compare_matrices(reader, before, after, regions)
        unexpected = [entry["group"] for entry in results if not entry["pass"]]
        report.update({"reader_sha256": reader_digest, "before_repeat_byte_pairs": before_pairs,
                       "after_repeat_byte_pairs": after_pairs, "groups": results, "unexpected_groups": unexpected})
        if regions:
            report["regions_sha256"] = REGIONS_SHA256
        report["status"] = "failed" if unexpected else "passed"
    except Exception as error:
        report["error"] = str(error)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "mode": arguments.mode,
                      "groups": len(report.get("groups", [])), "unexpected_groups": report.get("unexpected_groups", []),
                      "error": report.get("error")}, ensure_ascii=False))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
