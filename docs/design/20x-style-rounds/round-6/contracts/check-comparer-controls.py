import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import numpy
from PIL import Image


def fingerprints(directory):
    return {str(source.relative_to(directory)): hashlib.sha256(source.read_bytes()).hexdigest()
            for source in sorted(directory.rglob("*")) if source.is_file()}


def load_comparer(source):
    specification = importlib.util.spec_from_file_location("r6_control_comparer", source)
    comparer = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(comparer)
    return comparer


def pixel_controls(comparer, reader):
    scene = "workbench-empty-english-dark"
    original = numpy.zeros((820, 1120, 4), dtype=numpy.uint32)
    original[:, :, 3] = 255
    metadata = {field: None for field in reader.METADATA}
    cases = [
        ("unchanged", None, False, "header", 0, 0),
        ("inside-header", (700, 76), False, "header", 0, 0),
        ("left-boundary-outside", (479, 76), False, "header", 1, 1),
        ("right-boundary-outside", (1112, 76), False, "header", 1, 1),
        ("top-boundary-outside", (700, 47), False, "header", 1, 1),
        ("bottom-boundary-outside", (700, 104), False, "header", 1, 1),
        ("rgba-only-outside", (20, 20), True, "header", 0, 1),
        ("stability-header-pixel", (700, 76), False, "stability", 1, 1),
    ]
    checks = []
    for name, position, invisible, mode, expected_visible, expected_rgba in cases:
        first_rgba, second_rgba = original.copy(), original.copy()
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
        checks.append({"name": name, "layer": "decoded pixel mask", "synthetic_input": True, "pass": passed})
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
        assert entry["first_sha256"] == entry["second_sha256"]
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


def cli_controls(arguments, directory, contract):
    cases = [
        ("unchanged", None, True, 0, None),
        ("first-use-header-pixel", "workbench-empty-dark", True, 0, None),
        ("daily-header-pixel", "workbench-english", True, 0, None),
        ("main-pixel", "main-english", True, 1, None),
        ("composer-pixel", "composer-dark", True, 1, None),
        ("hash-corruption", "workbench-empty-dark", False, 1, "PNG hash mismatch"),
        ("repeat-byte-drift", None, True, 1, "Unstable PNG-byte repeat"),
        ("metadata-drift", None, True, 1, "Cross-matrix camera/fixture drift"),
        ("missing-scene", None, True, 1, "frozen 34 scenes"),
        ("wrong-first-use-scenario", None, True, 1, "Workbench scenario fixture mismatch"),
        ("wrong-first-use-marker", None, True, 1, "First-use marker fixture mismatch"),
        ("unexpected-fixture-exit", None, True, 1, "Unexpected fixture exit"),
    ]
    checks = []
    for name, scene, update_hashes, expected_exit, diagnostic in cases:
        synthetic = arguments.output / name
        shutil.copytree(arguments.before, synthetic)
        if scene is not None:
            alter_pixel(synthetic, scene, update_hashes)
        manifest_path = synthetic / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        if name == "repeat-byte-drift":
            source = synthetic / "workbench-empty-dark/repeat-2/capture.png"
            with Image.open(source) as image:
                image.save(source, compress_level=0)
            entry = next(item for item in manifest["comparisons"] if item["group"] == "workbench-empty-dark")
            entry["second_sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
            entry["byte_identical"] = False
        if name == "metadata-drift":
            for repeat in (1, 2):
                folder = synthetic / "workbench-empty-dark" / f"repeat-{repeat}"
                for filename in ("window.json", "capture.png.ready.json"):
                    path = folder / filename
                    metadata = json.loads(path.read_text())
                    metadata["window_frame"][0] += 1
                    path.write_text(json.dumps(metadata, indent=2) + "\n")
        if name == "missing-scene":
            manifest["comparisons"].pop()
        if name in ("wrong-first-use-scenario", "wrong-first-use-marker", "unexpected-fixture-exit"):
            for command in manifest["commands"]:
                if command["name"] not in ("workbench-empty-dark-repeat-1", "workbench-empty-dark-repeat-2"):
                    continue
                if name == "wrong-first-use-scenario":
                    command["command"][command["command"].index("-scenario") + 1] = "日常"
                elif name == "wrong-first-use-marker":
                    command["environment"].pop("PERCH_STYLE_FIRST_USE")
                else:
                    command["exit_code"] = 1
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        output = arguments.output / f"{name}.json"
        process = subprocess.run([
            sys.executable, "-B", str(directory / "compare-captures.py"), "--mode", "header",
            "--before", str(arguments.before), "--after", str(synthetic),
            "--before-head", contract["baseline_head"], "--after-head", contract["baseline_head"],
            "--output", str(output)
        ], env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"), capture_output=True, text=True)
        result = json.loads(output.read_text())
        passed = process.returncode == expected_exit
        if diagnostic is not None:
            passed = passed and diagnostic in result.get("error", "")
        checks.append({"name": name, "layer": "full frozen matrix CLI", "synthetic_input": True,
                       "actual_exit": process.returncode, "expected_exit": expected_exit,
                       "diagnostic": result.get("error"), "pass": passed})
    return checks


def frozen_controls(arguments, directory, comparer):
    cases = [
        ("frozen-contract.json", "Frozen contract hash mismatch"),
        ("expected-differences.md", "Frozen input hash mismatch"),
        ("allowed-regions-before.json", "Frozen input hash mismatch"),
        ("capture-matrix.py", "Frozen input hash mismatch"),
        ("capture-style-loop.py", "Frozen input hash mismatch"),
        ("protected-reader.py", "Protected round 3 PNG reader hash mismatch"),
    ]
    checks = []
    for filename, expected_error in cases:
        root = arguments.output / ("frozen-" + filename)
        target = root / "docs/design/20x-style-rounds/round-6/contracts"
        target.mkdir(parents=True)
        for name in ("compare-captures.py", "frozen-contract.json", "capture-matrix.py"):
            shutil.copyfile(directory / name, target / name)
        for name in ("expected-differences.md", "allowed-regions-before.json"):
            shutil.copyfile(directory.parent / name, target.parent / name)
        script = root / "scripts/capture-style-loop.py"
        script.parent.mkdir()
        shutil.copyfile(directory.parents[4] / "scripts/capture-style-loop.py", script)
        reader = root / "docs/design/20x-style-rounds/round-3/contracts/compare-captures.py"
        reader.parent.mkdir(parents=True)
        shutil.copyfile(directory.parents[1] / "round-3/contracts/compare-captures.py", reader)
        altered = target / filename
        if filename in ("expected-differences.md", "allowed-regions-before.json"):
            altered = target.parent / filename
        elif filename == "capture-style-loop.py":
            altered = script
        elif filename == "protected-reader.py":
            altered = reader
        altered.write_bytes(altered.read_bytes() + b"\n")
        isolated = load_comparer(target / "compare-captures.py")
        error = None
        try:
            isolated.load_contract(target)
            isolated.load_reader(target)
        except ValueError as exception:
            error = str(exception)
        checks.append({"name": "tampered-" + filename, "layer": "isolated frozen inputs", "synthetic_input": True,
                       "diagnostic": error, "pass": error is not None and expected_error in error})
    return checks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=False)
    directory = Path(__file__).resolve().parent
    protected_contracts = fingerprints(directory)
    protected_before = fingerprints(arguments.before) if arguments.before else None
    comparer = load_comparer(directory / "compare-captures.py")
    contract, regions = comparer.load_contract(directory)
    reader = comparer.load_reader(directory)
    checks = pixel_controls(comparer, reader) + frozen_controls(arguments, directory, comparer)
    if arguments.before:
        checks += cli_controls(arguments, directory, contract)
    unchanged = fingerprints(directory) == protected_contracts
    unchanged = unchanged and (arguments.before is None or fingerprints(arguments.before) == protected_before)
    report = {"status": "passed" if unchanged and all(check["pass"] for check in checks) else "failed",
              "synthetic_controls_only_not_delivery_screenshots": True, "controls": checks,
              "original_before_and_frozen_inputs_unchanged": unchanged,
              "before_input_files": len(protected_before) if protected_before is not None else 0,
              "frozen_contract_sha256": comparer.CONTRACT_SHA256}
    (arguments.output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "controls": len(checks), "originals_unchanged": unchanged}))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
