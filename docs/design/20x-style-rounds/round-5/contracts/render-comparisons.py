import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


HEADER = (544, 48, 1112, 104)
SCENES = (
    "workbench-light", "workbench-dark", "workbench-english", "workbench-english-dark",
    "workbench-large-type", "workbench-large-type-dark", "workbench-english-large-type",
    "workbench-english-large-type-dark", "workbench-empty-light",
)


def open_source(root, scene, phase, records):
    source = root / scene / "repeat-1/capture.png"
    records.append({"file": f"{phase}/{scene}/repeat-1/capture.png",
                    "sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "dimensions": [1120, 820]})
    with Image.open(source) as capture:
        rgba = capture.convert("RGBA")
    if rgba.size != (1120, 820):
        raise ValueError("Comparison source must match frozen Workbench geometry")
    background = Image.new("RGBA", rgba.size, "white")
    background.alpha_composite(rgba)
    return background.convert("RGB")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise ValueError("Derived comparison output must be new")
    arguments.output.mkdir(parents=True)
    font = ImageFont.load_default(size=20)
    records = []
    phases = [("before", arguments.before)]
    if arguments.after is not None:
        phases.append(("after", arguments.after))
    header_width = (HEADER[2] - HEADER[0]) * 3
    header_height = (HEADER[3] - HEADER[1]) * 3
    row_height = header_height + 36
    sheet = Image.new("RGB", (header_width * len(phases), row_height * len(SCENES)), "white")
    drawing = ImageDraw.Draw(sheet)
    for row, scene in enumerate(SCENES):
        for column, (phase, root) in enumerate(phases):
            image = open_source(root, scene, phase, records)
            crop = image.crop(HEADER).resize((header_width, header_height), Image.Resampling.NEAREST)
            drawing.text((column * header_width + 8, row * row_height + 5), f"{scene} / {phase}", fill="black", font=font)
            sheet.paste(crop, (column * header_width, row * row_height + 32))
    sheet.save(arguments.output / "headers.png")
    for scene in ("workbench-english", "workbench-english-dark"):
        pair = Image.new("RGB", (1120 * len(phases), 852), "white")
        drawing = ImageDraw.Draw(pair)
        for column, (phase, root) in enumerate(phases):
            image = open_source(root, scene, phase, records)
            drawing.text((column * 1120 + 8, 5), f"{scene} / {phase}", fill="black", font=font)
            pair.paste(image, (column * 1120, 32))
        pair.save(arguments.output / f"{scene}-full.png")
    report = {"purpose": "Derived view only; original capture PNGs are preserved separately",
              "header_crop_half_open": list(HEADER), "header_scale": 3, "header_resampling": "nearest",
              "full_window_resampling": "none", "transparent_pixels": "composited over white like the visible comparer",
              "sources": records, "outputs": [
                  {"file": source.name, "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}
                  for source in sorted(arguments.output.glob("*.png"))]}
    (arguments.output / "provenance.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": "passed", "phases": len(phases), "header_scenes": len(SCENES), "derived_pngs": 3}))


if __name__ == "__main__":
    raise SystemExit(main())
