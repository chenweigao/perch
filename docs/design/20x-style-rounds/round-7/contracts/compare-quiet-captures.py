import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

import numpy
from PIL import Image


ROOT = Path(__file__).resolve().parents[5]
ROUND = ROOT / "docs/design/20x-style-rounds/round-7"
PROFILE_SHA256 = "b767459491bc0eb17b1a3760eaf1037d770139396dfcf679da4a8e571eff37d7"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def protected_module(path, expected_hash, name):
    if digest(path) != expected_hash:
        raise ValueError(f"Protected reader hash mismatch: {name}")
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def load_profile():
    path = ROUND / "color-geometry-before.json"
    if digest(path) != PROFILE_SHA256:
        raise ValueError("Prewritten profile hash mismatch")
    profile = json.loads(path.read_text())
    bound = [
        (ROUND / "expected-differences.md", "expected_list_sha256"),
        (ROUND / "contracts/capture-matrix.py", "capture_wrapper_sha256"),
        (ROOT / "scripts/capture-style-loop.py", "existing_capture_driver_sha256"),
        (ROOT / "docs/design/20x-style-rounds/round-6/contracts/capture-matrix.py",
         "protected_round6_capture_wrapper_sha256"),
    ]
    if any(digest(path) != profile[field] for path, field in bound):
        raise ValueError("Frozen capture or expected-list input changed")
    if len(profile["scenes"]) != 34 or len(set(profile["scenes"])) != 34:
        raise ValueError("Frozen scene coverage mismatch")
    dark = {scene for scene in profile["scenes"] if scene.endswith("-dark")}
    if dark != set(profile["affected_scenes"]) or len(dark) != 15:
        raise ValueError("Only the fifteen frozen dark scenes may change")
    if set(profile["reference_geometry"]) != set(profile["scenes"]):
        raise ValueError("Frozen geometry coverage mismatch")
    reader = protected_module(
        ROOT / "docs/design/20x-style-rounds/round-6/contracts/compare-captures.py",
        profile["protected_matrix_reader_sha256"], "protected_round6_matrix_reader")
    png_reader = protected_module(
        ROOT / "docs/design/20x-style-rounds/round-3/contracts/compare-captures.py",
        profile["protected_png_reader_sha256"], "protected_round3_png_reader")
    return profile, reader, png_reader


def read_matrix(path, head, profile, reader, png_reader):
    geometry_contract = dict(profile)
    geometry_contract["affected_scenes"] = [
        scene for scene, geometry in profile["reference_geometry"].items()
        if geometry["dimensions"] == [1120, 820]
    ]
    captures = reader.read_matrix(path, head, geometry_contract, png_reader)
    for scene, capture in captures.items():
        geometry = profile["reference_geometry"][scene]
        height, width = capture["rgba"].shape[:2]
        if [width, height] != geometry["dimensions"]:
            raise ValueError(f"Frozen scene dimensions mismatch: {scene}")
        if capture["metadata"] != dict(capture["metadata"], **geometry["metadata"]):
            raise ValueError(f"Frozen scene camera or fixture mismatch: {scene}")
    return captures


def shifted_slices(height, width, row_offset, column_offset):
    top, bottom = max(0, -row_offset), min(height, height - row_offset)
    left, right = max(0, -column_offset), min(width, width - column_offset)
    return (slice(top, bottom), slice(left, right)), (
        slice(top + row_offset, bottom + row_offset),
        slice(left + column_offset, right + column_offset))


def foreground_mask(rgba, rules):
    rgb = rgba[:, :, :3]
    height, width = rgb.shape[:2]
    edges = numpy.zeros((height, width), dtype=bool)
    for row_offset in range(-1, 2):
        for column_offset in range(-1, 2):
            if row_offset == column_offset == 0:
                continue
            first, second = shifted_slices(height, width, row_offset, column_offset)
            edges[first] |= numpy.any(rgb[first] != rgb[second], axis=2)
    mask = numpy.zeros_like(edges)
    radius = rules["chebyshev_dilation_radius"]
    for row_offset in range(-radius, radius + 1):
        for column_offset in range(-radius, radius + 1):
            first, second = shifted_slices(height, width, row_offset, column_offset)
            mask[first] |= edges[second]
    distance = numpy.abs(rgb.astype(numpy.int16) - numpy.array(rules["quiet_srgb_seed"]))
    mask |= numpy.all(distance <= rules["quiet_seed_maximum_channel_distance"], axis=2)
    return mask


def invalid_color_pixels(before, after, rules):
    increment = after.astype(numpy.int16) - before.astype(numpy.int16)
    invalid = numpy.any(increment < rules["minimum_rgb_channel_increment"], axis=2)
    invalid |= numpy.any(increment > rules["maximum_rgb_channel_increment"], axis=2)
    invalid |= numpy.ptp(increment, axis=2) > rules["maximum_increment_channel_span"]
    return invalid


def source_unchanged(head):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    current = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                      text=True, env=environment).strip()
    changed = subprocess.check_output([
        "git", "diff", "--name-only", head, "--", "Sources", "Tests", "scripts",
        ".github", "Package.swift", "Package.resolved", "AGENTS.md"],
        cwd=ROOT, text=True, env=environment).strip()
    if current != head or changed:
        raise ValueError("Mask freeze must precede every product/source change")


def freeze_masks(path, captures, profile):
    source_unchanged(profile["baseline_head"])
    directory = ROUND / "frozen-masks"
    directory.mkdir(exist_ok=False)
    records = {}
    for scene in sorted(profile["affected_scenes"]):
        capture = captures[scene]
        mask = foreground_mask(capture["rgba"], profile["mask_rules"])
        target = directory / (scene + ".png")
        Image.fromarray(mask.astype(numpy.uint8) * 255).save(target)
        records[scene] = {
            "file": str(target.relative_to(ROUND)), "sha256": digest(target),
            "dimensions": list(mask.shape[::-1]), "allowed_pixels": int(mask.sum()),
            "before_original_png_sha256": digest(path / scene / "repeat-1/capture.png"),
        }
    return {"masks": records, "source_unchanged_at_freeze": True,
            "original_before_manifest_sha256": digest(path / "manifest.json"),
            "comparison_source_sha256": digest(Path(__file__)),
            "mask_rules": profile["mask_rules"], "color_rules": profile["color_rules"]}


def load_masks(before_path, captures, profile, expected_freeze_hash):
    frozen_path = ROUND / "frozen-masks.json"
    if digest(frozen_path) != expected_freeze_hash:
        raise ValueError("Preproduct mask-freeze payload hash mismatch")
    frozen = json.loads(frozen_path.read_text())
    if frozen["status"] != "passed" or frozen["mode"] != "freeze":
        raise ValueError("Mask freeze did not pass")
    if frozen["profile_sha256"] != PROFILE_SHA256 or not frozen["source_unchanged_at_freeze"]:
        raise ValueError("Masks were not bound before the product change")
    if frozen["comparison_source_sha256"] != digest(Path(__file__)):
        raise ValueError("Comparison rules changed after the mask freeze")
    if frozen["before_head"] != profile["baseline_head"]:
        raise ValueError("Wrong frozen mask source head")
    if frozen["mask_rules"] != profile["mask_rules"] or frozen["color_rules"] != profile["color_rules"]:
        raise ValueError("Frozen color or mask rules changed")
    if set(frozen["masks"]) != set(profile["affected_scenes"]):
        raise ValueError("Frozen mask scene coverage mismatch")
    masks = {}
    for scene, record in frozen["masks"].items():
        path = ROUND / record["file"]
        if path != ROUND / "frozen-masks" / (scene + ".png"):
            raise ValueError(f"Unexpected frozen mask path: {scene}")
        if digest(path) != record["sha256"]:
            raise ValueError(f"Frozen mask hash mismatch: {scene}")
        if digest(before_path / scene / "repeat-1/capture.png") != record["before_original_png_sha256"]:
            raise ValueError(f"Frozen original before PNG mismatch: {scene}")
        with Image.open(path) as image:
            pixels = numpy.array(image)
        if pixels.shape != captures[scene]["rgba"].shape[:2] or not numpy.all((pixels == 0) | (pixels == 255)):
            raise ValueError(f"Frozen binary mask dimensions or values mismatch: {scene}")
        masks[scene] = pixels == 255
        if int(masks[scene].sum()) != record["allowed_pixels"]:
            raise ValueError(f"Frozen mask pixel count mismatch: {scene}")
    return masks


def compare(before_path, after_path, before, after, profile, masks, reader, mode):
    groups = []
    for scene in profile["scenes"]:
        first, second = before[scene], after[scene]
        if first["environment"] != second["environment"]:
            raise ValueError(f"Cross-job fixture environment mismatch: {scene}")
        changed_rgba = numpy.any(first["rgba"] != second["rgba"], axis=2)
        changed_visible = numpy.any(first["visible"] != second["visible"], axis=2)
        mask = masks.get(scene, numpy.zeros_like(changed_rgba)) if mode == "color" else numpy.zeros_like(changed_rgba)
        outside_rgba = changed_rgba & ~mask
        outside_visible = changed_visible & ~mask
        invalid = invalid_color_pixels(first["rgba"][:, :, :3], second["rgba"][:, :, :3], profile["color_rules"])
        invalid |= invalid_color_pixels(first["visible"], second["visible"], profile["color_rules"])
        alpha_changed = first["rgba"][:, :, 3] != second["rgba"][:, :, 3]
        transparent_changed = changed_rgba & (first["rgba"][:, :, 3] == 0)
        bytes_identical = all(digest(before_path / scene / f"repeat-{repeat}/capture.png") ==
                              digest(after_path / scene / f"repeat-{repeat}/capture.png") for repeat in (1, 2))
        required_bytes = mode == "stability" or scene not in profile["affected_scenes"]
        passed = not bool(outside_rgba.any() or outside_visible.any() or invalid.any() or alpha_changed.any() or transparent_changed.any())
        passed = passed and (not required_bytes or bytes_identical)
        groups.append({
            "group": scene, "dimensions": list(changed_rgba.shape[::-1]),
            "changed_rgba_pixels": int(changed_rgba.sum()), "changed_visible_pixels": int(changed_visible.sum()),
            "changed_rgba_bbox": reader.bounds(changed_rgba), "changed_visible_bbox": reader.bounds(changed_visible),
            "outside_allowed_rgba_pixels": int(outside_rgba.sum()),
            "outside_allowed_visible_pixels": int(outside_visible.sum()),
            "unexpected_color_pixels": int(invalid.sum()), "changed_alpha_pixels": int(alpha_changed.sum()),
            "transparent_rgba_changed_pixels": int(transparent_changed.sum()),
            "cross_job_png_bytes_identical": bytes_identical, "pass": passed,
        })
    return groups


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--before-head", required=True)
    parser.add_argument("--after", type=Path)
    parser.add_argument("--after-head")
    parser.add_argument("--masks-sha256")
    parser.add_argument("--mode", choices=("baseline", "freeze", "color", "stability"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise ValueError("Refusing to overwrite an existing verification result")
    report = {"status": "failed", "mode": arguments.mode,
              "verified_at": datetime.now().astimezone().isoformat(timespec="seconds"),
              "before_head": arguments.before_head, "after_head": arguments.after_head,
              "profile_sha256": PROFILE_SHA256, "tolerance_outside_frozen_mask": 0}
    try:
        profile, reader, png_reader = load_profile()
        if arguments.before_head != profile["baseline_head"]:
            raise ValueError("Wrong frozen baseline head")
        before = read_matrix(arguments.before, arguments.before_head, profile, reader, png_reader)
        report.update(before_repeat_byte_pairs=34, before_repeat_pixel_pairs=34, before_original_pngs=68)
        if arguments.mode in ("baseline", "freeze"):
            if arguments.after is not None or arguments.after_head is not None:
                raise ValueError("Baseline/freeze cannot consume after inputs")
            if arguments.mode == "freeze":
                report.update(freeze_masks(arguments.before, before, profile))
            report["status"] = "passed"
        else:
            if arguments.after is None or arguments.after_head is None:
                raise ValueError("Cross-job verification requires the after matrix and head")
            if arguments.mode == "stability" and arguments.before_head != arguments.after_head:
                raise ValueError("Whole-window cross-job stability requires the same head")
            after = read_matrix(arguments.after, arguments.after_head, profile, reader, png_reader)
            if arguments.mode == "color" and not arguments.masks_sha256:
                raise ValueError("Color verification requires the preproduct mask-freeze SHA256")
            masks = load_masks(arguments.before, before, profile, arguments.masks_sha256) if arguments.mode == "color" else {}
            groups = compare(arguments.before, arguments.after, before, after, profile, masks, reader, arguments.mode)
            required = profile["color_rules"]["required_changed_scenes"] if arguments.mode == "color" else []
            missing = [scene for scene in required if not next(group for group in groups if group["group"] == scene)["changed_rgba_pixels"]]
            report.update(after_repeat_byte_pairs=34, after_repeat_pixel_pairs=34, after_original_pngs=68,
                          frozen_masks_sha256=arguments.masks_sha256,
                          groups=groups, unchanged_light_scenes=19, affected_dark_scenes=15,
                          missing_required_changes=missing,
                          unexpected_groups=[group["group"] for group in groups if not group["pass"]])
            if not missing and all(group["pass"] for group in groups):
                report["status"] = "passed"
    except (AssertionError, KeyError, ValueError, OSError) as error:
        report["error"] = str(error)
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key not in ("groups", "masks")}, ensure_ascii=False))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
