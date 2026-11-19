import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw


def main():
    output_root = Path("failed-find-crops-v1")
    if output_root.exists():
        raise ValueError("Refusing to overwrite derived evidence")
    output_root.mkdir()
    crop = (264, 38, 1248, 104)
    records = []
    for scene in ("main-find", "main-find-dark"):
        before = Path("before-original/capture") / scene / "repeat-1/capture.png"
        after = Path("after-original/capture") / scene / "repeat-1/capture.png"
        original_hashes = [hashlib.sha256(path.read_bytes()).hexdigest() for path in (before, after)]
        panels = []
        for source in (before, after):
            with Image.open(source) as image:
                cropped = image.convert("RGBA").crop(crop)
                background = Image.new("RGBA", cropped.size, "white")
                background.alpha_composite(cropped)
                panels.append(background.convert("RGB").resize((cropped.width * 3, cropped.height * 3), Image.Resampling.NEAREST))
        panel_width, panel_height = panels[0].size
        canvas = Image.new("RGB", (panel_width, panel_height * 2 + 80), "white")
        drawing = ImageDraw.Draw(canvas)
        drawing.text((12, 10), f"{scene} BEFORE - original crop, nearest-neighbor 3x", fill="black")
        drawing.text((12, panel_height + 50), f"{scene} AFTER - original crop, nearest-neighbor 3x", fill="black")
        canvas.paste(panels[0], (0, 32))
        canvas.paste(panels[1], (0, panel_height + 72))
        destination = output_root / (scene + "-3x.png")
        canvas.save(destination)
        assert original_hashes == [hashlib.sha256(path.read_bytes()).hexdigest() for path in (before, after)]
        records.append({"scene": scene, "before_png": str(before), "after_png": str(after),
                        "before_sha256": original_hashes[0], "after_sha256": original_hashes[1],
                        "crop_pixels": list(crop), "scale": 3, "resampling": "nearest",
                        "derived_png": destination.name,
                        "derived_sha256": hashlib.sha256(destination.read_bytes()).hexdigest()})
    result = {"status": "generated", "scope": "Illustration only, not quantitative comparison or a replacement for originals",
              "raw_originals_unchanged": True, "outside_alpha_composited_on_white": True,
              "crop_chosen_after_failure_only_for_observation_not_contract": True, "records": records}
    (output_root / "crop-provenance.json").write_text(json.dumps(result, indent=2) + "\n")
    print("Generated two lossless 3x find-bar illustrations; original hashes unchanged.")


if __name__ == "__main__":
    main()
