import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

from PIL import Image


BASELINE = "aad604b9ce5294b52951f189b3895b69edd12f31"


def fingerprints(directory):
    return {str(source.relative_to(directory)): hashlib.sha256(source.read_bytes()).hexdigest()
            for source in sorted(directory.rglob("*")) if source.is_file()}


def alter_pixel(directory, scene, position, update_hashes):
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    entry = next(item for item in manifest["comparisons"] if item["group"] == scene)
    for repeat, hash_key in ((1, "first_sha256"), (2, "second_sha256")):
        source = directory / scene / f"repeat-{repeat}/capture.png"
        with Image.open(source) as capture:
            image = capture.convert("RGBA")
        pixel = image.getpixel(position)
        image.putpixel(position, (255 - pixel[0], 255 - pixel[1], 255 - pixel[2], 255))
        image.save(source)
        if update_hashes:
            entry[hash_key] = hashlib.sha256(source.read_bytes()).hexdigest()
    if update_hashes:
        assert entry["first_sha256"] == entry["second_sha256"]
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise ValueError("Synthetic control output must be new")
    protected = fingerprints(arguments.before)
    arguments.output.mkdir(parents=True)
    contracts = Path(__file__).resolve().parent
    cases = [
        ("unchanged", None, None, True, 0),
        ("header-pixel", "main-english", (1240, 64), True, 0),
        ("file-row-pixel", "main-english", (1240, 120), True, 1),
        ("composer-pixel", "composer-dark", (380, 250), True, 1),
        ("hash-corruption", "main-english", (1240, 64), False, 1),
    ]
    checks = []
    for name, scene, position, update_hashes, expected_exit in cases:
        synthetic = arguments.output / name
        shutil.copytree(arguments.before, synthetic)
        if scene is not None:
            alter_pixel(synthetic, scene, position, update_hashes)
        report_path = arguments.output / f"{name}-result.json"
        command = [sys.executable, str(contracts / "compare-captures.py"),
                   "--before", str(arguments.before), "--after", str(synthetic),
                   "--before-head", BASELINE, "--after-head", BASELINE,
                   "--mode", "header", "--expected-list", str(contracts.parent / "expected-differences.md"),
                   "--allowed", str(contracts.parent / "allowed-regions-before.json"),
                   "--output", str(report_path)]
        process = subprocess.run(command, capture_output=True, text=True)
        (arguments.output / f"{name}.log").write_text(process.stdout + process.stderr)
        result = json.loads(report_path.read_text())
        check = {"case": name, "layer": "full header CLI", "synthetic_input": True,
                 "expected_exit": expected_exit, "actual_exit": process.returncode,
                 "comparer_status": result["status"], "pass": process.returncode == expected_exit}
        if scene is not None and update_hashes:
            group = next(item for item in result["groups"] if item["group"] == scene)
            check.update({key: group[key] for key in (
                "changed_visible_pixels", "changed_rgba_pixels", "outside_allowed_visible_pixels",
                "outside_allowed_rgba_pixels", "changed_visible_bbox")})
            check["pass"] = check["pass"] and group["changed_visible_pixels"] == 1
            check["pass"] = check["pass"] and group["changed_rgba_pixels"] == 1
            check["pass"] = check["pass"] and group["outside_allowed_visible_pixels"] == expected_exit
            check["pass"] = check["pass"] and group["outside_allowed_rgba_pixels"] == expected_exit
        if name == "hash-corruption":
            check["diagnostic"] = result.get("error")
            check["pass"] = check["pass"] and "PNG hash mismatch" in result.get("error", "")
        checks.append(check)
    unchanged = protected == fingerprints(arguments.before)
    passed = unchanged and all(check["pass"] for check in checks)
    summary = {"status": "passed" if passed else "failed",
               "purpose": "Synthetic corruption controls, not delivery screenshots or a product verdict",
               "source_matrix_head": BASELINE, "protected_original_files": len(protected),
               "protected_originals_unchanged": unchanged, "control_count": len(checks), "checks": checks}
    arguments.report.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"status": summary["status"], "controls": len(checks),
                      "protected_originals_unchanged": unchanged}))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
