import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw


SCENES = [
    "main-english", "main-english-dark", "main-english-large-type", "main-english-large-type-dark",
    "main-light", "main-dark", "main-large-type", "main-large-type-dark",
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--regions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--index", type=Path, required=True)
    arguments = parser.parse_args()
    regions = json.loads(arguments.regions.read_text())["scenarios"]
    canvas = Image.new("RGB", (1248, len(SCENES) * 136), "white")
    drawing = ImageDraw.Draw(canvas)
    records = []
    for row_index, scene in enumerate(SCENES):
        drawing.text((6, row_index * 136 + 8), scene + " / BEFORE", fill="black")
        drawing.text((630, row_index * 136 + 8), scene + " / AFTER", fill="black")
        for column_index, capture_root in enumerate((arguments.before, arguments.after)):
            source = capture_root / scene / "repeat-1/capture.png"
            with Image.open(source) as screenshot:
                cropped = screenshot.crop(regions[scene]).convert("RGBA")
            visible = Image.alpha_composite(Image.new("RGBA", cropped.size, "white"), cropped).convert("RGB")
            canvas.paste(visible.resize((624, 104), Image.Resampling.NEAREST),
                         (column_index * 624, row_index * 136 + 28))
            records.append({"source": str(source), "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                            "crop": regions[scene], "scale": 2, "resampling": "nearest", "scene": scene})
    canvas.save(arguments.output)
    arguments.index.write_text(json.dumps({"scope": "Annotated crop copies; original PNG files unchanged",
                                           "sources": records}, indent=2) + "\n")


if __name__ == "__main__":
    main()
