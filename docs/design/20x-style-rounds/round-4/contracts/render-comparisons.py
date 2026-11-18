import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


SCENES = ["main-light", "main-dark", "main-english", "main-english-dark",
          "main-large-type", "main-large-type-dark", "main-english-large-type",
          "main-english-large-type-dark"]
HEADER = [1218, 44, 1530, 96]


def visible_image(source):
    with Image.open(source) as capture:
        rgba = capture.convert("RGBA")
    return Image.alpha_composite(Image.new("RGBA", rgba.size, "white"), rgba).convert("RGB")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)
    headers = arguments.output / "headers-before-after.png"
    provenance_path = arguments.output / "provenance.json"
    if headers.exists() or provenance_path.exists():
        raise ValueError("Comparison artifacts must be new")
    font = ImageFont.truetype("DejaVuSans.ttf", 18)
    grid = Image.new("RGB", (1872, 194 * len(SCENES)), "#eeeeee")
    paint = ImageDraw.Draw(grid)
    sources = []
    for row, scene in enumerate(SCENES):
        for column, (phase, root) in enumerate((("before", arguments.before), ("after", arguments.after))):
            source = root / scene / "repeat-1/capture.png"
            image = visible_image(source)
            if image.size != (1536, 900):
                raise ValueError("Header crop requires the verified original geometry")
            crop = image.crop(HEADER).resize((936, 156), Image.Resampling.NEAREST)
            origin = (column * 936, row * 194)
            paint.text((origin[0] + 8, origin[1] + 5), f"{phase} / {scene} / 3x nearest", fill="black", font=font)
            grid.paste(crop, (origin[0], origin[1] + 36))
            sources.append({"phase": phase, "scene": scene, "source": str(source.relative_to(root)),
                            "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                            "crop_half_open": HEADER, "scale": 3, "resampling": "nearest"})
    grid.save(headers)
    full_pairs = []
    for scene in ("main-english", "main-english-dark"):
        destination = arguments.output / f"{scene}-full-before-after.png"
        if destination.exists():
            raise ValueError("Full-window comparison must be new")
        pair = Image.new("RGB", (3072, 948), "#eeeeee")
        painter = ImageDraw.Draw(pair)
        for column, (phase, root) in enumerate((("before", arguments.before), ("after", arguments.after))):
            source = root / scene / "repeat-1/capture.png"
            painter.text((column * 1536 + 12, 12), f"{phase} / {scene} / original scale", fill="black", font=font)
            pair.paste(visible_image(source), (column * 1536, 48))
        pair.save(destination)
        full_pairs.append({"scene": scene, "artifact": destination.name,
                           "source": f"{scene}/repeat-1/capture.png", "scale": 1, "resampling": "none"})
    before_manifest = json.loads((arguments.before / "manifest.json").read_text())
    after_manifest = json.loads((arguments.after / "manifest.json").read_text())
    provenance_path.write_text(json.dumps({"purpose": "Derived comparison illustrations; canonical PNGs are untouched",
                                          "before_head": before_manifest["commit"], "after_head": after_manifest["commit"],
                                          "headers": sources, "full_window_pairs": full_pairs}, indent=2) + "\n")
    print(json.dumps({"header_pairs": len(SCENES), "full_window_pairs": len(full_pairs)}))


if __name__ == "__main__":
    main()
