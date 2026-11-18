import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw


METADATA_KEYS = (
    "appearance", "backing_scale", "content_bounds", "dark", "effective_dark",
    "large_type", "locale", "window_frame",
)


def visible_image(path):
    with Image.open(path) as screenshot:
        screenshot.verify()
    with Image.open(path) as screenshot:
        foreground = screenshot.convert("RGBA")
    background = Image.new("RGBA", foreground.size, (255, 255, 255, 255))
    return Image.alpha_composite(background, foreground).convert("RGB")


def pixel_difference(first, second):
    if first.size != second.size:
        raise ValueError("Screenshot dimensions differ")
    channels = ImageChops.difference(first, second).split()
    return ImageChops.lighter(ImageChops.lighter(channels[0], channels[1]), channels[2])


def changed_pixels(mask):
    return mask.width * mask.height - mask.histogram()[0]


def metadata(path):
    values = json.loads(path.read_text())
    return {key: values.get(key) for key in METADATA_KEYS}


def relative_path(path):
    try:
        return str(path.resolve().relative_to(Path.cwd().resolve()))
    except ValueError:
        return path.name


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--regions", type=Path, required=True)
    parser.add_argument("--expected-list", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    before_manifest = json.loads((arguments.before / "manifest.json").read_text())
    after_manifest = json.loads((arguments.after / "manifest.json").read_text())
    if before_manifest["status"] != "passed" or after_manifest["status"] != "passed":
        raise ValueError("Both capture jobs must pass before comparison")
    groups = sorted(entry["group"] for entry in before_manifest["comparisons"])
    if groups != sorted(entry["group"] for entry in after_manifest["comparisons"]):
        raise ValueError("Capture scene matrices differ")
    before_records = {entry["group"]: entry for entry in before_manifest["comparisons"]}
    after_records = {entry["group"]: entry for entry in after_manifest["comparisons"]}
    regions = json.loads(arguments.regions.read_text())["scenarios"]
    comparisons = []
    for group in groups:
        before_paths = [arguments.before / group / f"repeat-{repeat}" for repeat in (1, 2)]
        after_paths = [arguments.after / group / f"repeat-{repeat}" for repeat in (1, 2)]
        images = [visible_image(path / "capture.png") for path in before_paths + after_paths]
        metadata_values = [metadata(path / "window.json") for path in before_paths + after_paths]
        comparable = all(value == metadata_values[0] for value in metadata_values[1:])
        before_stable = changed_pixels(pixel_difference(images[0], images[1])) == 0
        after_stable = changed_pixels(pixel_difference(images[2], images[3])) == 0
        difference = pixel_difference(images[0], images[2])
        outside = difference.copy()
        allowed = regions.get(group)
        if allowed is not None:
            left, top, right, bottom = allowed
            if not (0 <= left < right <= difference.width and 0 <= top < bottom <= difference.height):
                raise ValueError(f"Invalid predeclared region: {group}")
            ImageDraw.Draw(outside).rectangle((left, top, right - 1, bottom - 1), fill=0)
        hashes = [hashlib.sha256((path / "capture.png").read_bytes()).hexdigest()
                  for path in before_paths + after_paths]
        declared_hashes = [before_records[group]["first_sha256"], before_records[group]["second_sha256"],
                           after_records[group]["first_sha256"], after_records[group]["second_sha256"]]
        comparisons.append({
            "group": group,
            "before": relative_path(before_paths[0] / "capture.png"),
            "after": relative_path(after_paths[0] / "capture.png"),
            "dimensions": list(images[0].size),
            "comparable": comparable,
            "manifest_hashes_match": hashes == declared_hashes,
            "before_repeat_stable": before_stable,
            "after_repeat_stable": after_stable,
            "before_byte_identical": hashes[0] == hashes[1],
            "after_byte_identical": hashes[2] == hashes[3],
            "changed_pixels": changed_pixels(difference),
            "changed_bounds": difference.getbbox(),
            "allowed_region": allowed,
            "unexpected_pixels": changed_pixels(outside),
        })
    passed = all(entry["comparable"] and entry["manifest_hashes_match"] and entry["before_repeat_stable"]
                 and entry["after_repeat_stable"] and entry["unexpected_pixels"] == 0
                 for entry in comparisons)
    result = {
        "status": "passed" if passed else "failed",
        "comparison": "Pillow-decoded RGB composited over white; fixed before-declared regions",
        "before_commit": before_manifest["commit"],
        "after_commit": after_manifest["commit"],
        "expected_list_sha256": hashlib.sha256(arguments.expected_list.read_bytes()).hexdigest(),
        "regions_sha256": hashlib.sha256(arguments.regions.read_bytes()).hexdigest(),
        "scene_count": len(comparisons),
        "scenarios": comparisons,
    }
    arguments.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": result["status"], "scenes": len(comparisons),
                      "unexpected_pixels": sum(entry["unexpected_pixels"] for entry in comparisons)}))
    if not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
