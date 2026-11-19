import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

import numpy
from PIL import Image


def fingerprints(directory):
    return {str(source.relative_to(directory)): hashlib.sha256(source.read_bytes()).hexdigest()
            for source in sorted(directory.rglob("*")) if source.is_file()}


def load_comparer(directory):
    specification = importlib.util.spec_from_file_location("round_five_comparer", directory / "compare-captures.py")
    if specification is None or specification.loader is None:
        raise ValueError("Unable to load round 5 comparer")
    comparer = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(comparer)
    return comparer


def pixel_controls(comparer, reader):
    scene = "workbench-english"
    original = numpy.zeros((820, 1120, 4), dtype=numpy.uint32)
    original[:, :, 3] = 255
    metadata = {field: None for field in reader.METADATA}
    checks = []
    cases = [
        ("unchanged", None, False, "header", 0, 0),
        ("inside-header", (700, 76), False, "header", 0, 0),
        ("left-boundary-outside", (543, 76), False, "header", 1, 1),
        ("right-boundary-outside", (1112, 76), False, "header", 1, 1),
        ("top-boundary-outside", (700, 47), False, "header", 1, 1),
        ("bottom-boundary-outside", (700, 104), False, "header", 1, 1),
        ("rgba-only-outside", (20, 20), True, "header", 0, 1),
        ("stability-header-pixel", (700, 76), False, "stability", 1, 1),
    ]
    for name, position, invisible, mode, expected_visible, expected_rgba in cases:
        first_rgba = original.copy()
        second_rgba = original.copy()
        if position is not None:
            horizontal, vertical = position
            if invisible:
                first_rgba[vertical, horizontal, 3] = 0
                second_rgba[vertical, horizontal, 3] = 0
            second_rgba[vertical, horizontal, 0] = 1
        captures = []
        for rgba in (first_rgba, second_rgba):
            alpha = rgba[:, :, 3:4]
            visible = ((rgba[:, :, :3] * alpha + 255 * (255 - alpha) + 127) // 255).astype(numpy.int16)
            captures.append({scene: {"rgba": rgba, "visible": visible, "metadata": metadata, "environment": {}}})
        result = comparer.compare(captures[0], captures[1], mode, {scene: comparer.HEADER}, reader)[0]
        passed = result["outside_allowed_visible_pixels"] == expected_visible
        passed = passed and result["outside_allowed_rgba_pixels"] == expected_rgba
        passed = passed and result["pass"] == (expected_visible == 0 and expected_rgba == 0)
        checks.append({"name": name, "layer": "decoded pixel mask", "synthetic_input": True,
                       "outside_allowed_visible_pixels": result["outside_allowed_visible_pixels"],
                       "outside_allowed_rgba_pixels": result["outside_allowed_rgba_pixels"], "pass": passed})
    return checks


def alter_pixel(directory, scene, update_hashes):
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    entry = next(item for item in manifest["comparisons"] if item["group"] == scene)
    position = (700, 76) if scene.startswith("workbench-") else (50, 50)
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
        if entry["first_sha256"] != entry["second_sha256"]:
            raise ValueError("Synthetic repeat encoding unexpectedly differs")
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


def cli_controls(arguments, directory, contract):
    cases = [
        ("unchanged", None, True, 0, None),
        ("header-pixel", "workbench-english", True, 0, None),
        ("main-pixel", "main-english", True, 1, None),
        ("composer-pixel", "composer-dark", True, 1, None),
        ("hash-corruption", "workbench-english", False, 1, "PNG hash mismatch"),
        ("repeat-byte-drift", None, True, 1, "Unstable PNG-byte repeat"),
        ("metadata-drift", None, True, 1, "Cross-matrix camera/fixture drift"),
        ("missing-scene", None, True, 1, "frozen 27 scenes"),
    ]
    checks = []
    for name, scene, update_hashes, expected_exit, diagnostic in cases:
        synthetic = arguments.output / name
        shutil.copytree(arguments.before, synthetic)
        if scene is not None:
            alter_pixel(synthetic, scene, update_hashes)
        if name == "repeat-byte-drift":
            source = synthetic / "workbench-english/repeat-2/capture.png"
            with Image.open(source) as image:
                image.save(source, compress_level=0)
            manifest_path = synthetic / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            entry = next(item for item in manifest["comparisons"] if item["group"] == "workbench-english")
            entry["second_sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
            entry["byte_identical"] = False
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        if name == "metadata-drift":
            for repeat in (1, 2):
                folder = synthetic / "workbench-english" / f"repeat-{repeat}"
                for filename in ("window.json", "capture.png.ready.json"):
                    source = folder / filename
                    metadata = json.loads(source.read_text())
                    metadata["window_frame"] = "synthetic camera drift"
                    source.write_text(json.dumps(metadata, indent=2) + "\n")
        if name == "missing-scene":
            manifest_path = synthetic / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["comparisons"].pop()
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        report_path = arguments.output / f"{name}-result.json"
        command = [sys.executable, "-B", str(directory / "compare-captures.py"),
                   "--before", str(arguments.before), "--after", str(synthetic),
                   "--before-head", contract["baseline_head"], "--after-head", contract["baseline_head"],
                   "--mode", "header", "--output", str(report_path)]
        process = subprocess.run(command, capture_output=True, text=True)
        (arguments.output / f"{name}.log").write_text(process.stdout + process.stderr)
        result = json.loads(report_path.read_text())
        passed = process.returncode == expected_exit
        if diagnostic is not None:
            passed = passed and diagnostic in result.get("error", "")
        checks.append({"name": name, "layer": "full frozen matrix CLI", "synthetic_input": True,
                       "expected_exit": expected_exit, "actual_exit": process.returncode,
                       "comparer_status": result["status"], "diagnostic": result.get("error"), "pass": passed})
    return checks


def frozen_controls(arguments, directory, comparer):
    checks = []
    for name in ("frozen-contract", "allowed-region", "expected-list"):
        root = arguments.output / name
        target = root / "docs/design/20x-style-rounds/round-5/contracts"
        target.mkdir(parents=True)
        for filename in ("frozen-contract.json", "capture-matrix.py"):
            shutil.copy2(directory / filename, target / filename)
        for filename in ("expected-differences.md", "allowed-regions-before.json"):
            shutil.copy2(directory.parent / filename, target.parent / filename)
        (root / "scripts").mkdir()
        shutil.copy2(directory.parents[4] / "scripts/capture-style-loop.py", root / "scripts/capture-style-loop.py")
        source = {"frozen-contract": target / "frozen-contract.json",
                  "allowed-region": target.parent / "allowed-regions-before.json",
                  "expected-list": target.parent / "expected-differences.md"}[name]
        source.write_bytes(source.read_bytes() + b"\n")
        diagnostic = None
        try:
            comparer.load_contract(target)
        except ValueError as error:
            diagnostic = str(error)
        checks.append({"name": name, "layer": "frozen input binding", "synthetic_input": True,
                       "diagnostic": diagnostic, "pass": diagnostic is not None and "hash mismatch" in diagnostic})
    return checks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise ValueError("Synthetic control output must be new")
    protected = fingerprints(arguments.before)
    directory = Path(__file__).resolve().parent
    protected_contracts = fingerprints(directory)
    comparer = load_comparer(directory)
    contract, regions = comparer.load_contract(directory)
    reader = comparer.load_reader(directory)
    arguments.output.mkdir(parents=True)
    checks = pixel_controls(comparer, reader)
    checks.extend(cli_controls(arguments, directory, contract))
    checks.extend(frozen_controls(arguments, directory, comparer))
    unchanged = protected == fingerprints(arguments.before) and protected_contracts == fingerprints(directory)
    summary = {"status": "passed" if unchanged and all(check["pass"] for check in checks) else "failed",
               "purpose": "Synthetic corruption controls, not delivery screenshots or a product verdict",
               "source_matrix_head": contract["baseline_head"], "protected_original_files": len(protected),
               "protected_contract_files": len(protected_contracts), "protected_originals_unchanged": unchanged,
               "control_count": len(checks), "checks": checks}
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    arguments.report.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": summary["status"], "controls": len(checks), "protected_originals_unchanged": unchanged}))
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
