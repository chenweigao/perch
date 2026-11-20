#!/usr/bin/env python3
"""Capture fixed native narrow fixtures through the existing style capture path."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import time


SCENES = {
    "light": {},
    "dark": {"PERCH_STYLE_DARK": "1"},
    "english": {"PERCH_STYLE_LOCALE": "en"},
    "english-dark": {"PERCH_STYLE_LOCALE": "en", "PERCH_STYLE_DARK": "1"},
    "large-type": {"PERCH_STYLE_LARGE_TYPE": "1"},
    "large-type-dark": {"PERCH_STYLE_LARGE_TYPE": "1", "PERCH_STYLE_DARK": "1"},
    "english-large": {"PERCH_STYLE_LOCALE": "en", "PERCH_STYLE_LARGE_TYPE": "1"},
    "english-large-dark": {"PERCH_STYLE_LOCALE": "en", "PERCH_STYLE_LARGE_TYPE": "1", "PERCH_STYLE_DARK": "1"},
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    with path.open("x") as output:
        json.dump(value, output, ensure_ascii=False, indent=2)
        output.write("\n")


def capture(binary, domain, node, output, settings):
    output.mkdir(parents=True)
    screenshot = output / "capture.png"
    ready = Path(str(screenshot) + ".ready.json")
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("PERCH_STYLE_") and key != "PERCH_DESIGN_CAPTURES"}
    environment.update(settings, PERCH_STYLE_CAPTURE=str(screenshot), PERCH_STYLE_CAPTURE_SIZE="836x900")
    entry = {"started_at": datetime.now().astimezone().isoformat(timespec="milliseconds"),
             "settings": settings, "requested_capture_size": [836, 900], "capture_exit": None,
             "fixture_exit_after_cleanup": None}
    process = None
    with tempfile.TemporaryDirectory(prefix="perch-style-narrow-") as fixture_temp:
        environment["TMPDIR"] = str(Path(fixture_temp).resolve()) + "/"
        entry["fixture_TMPDIR"] = environment["TMPDIR"]
        with (output / "preferences-before.log").open("xb") as log:
            entry["preferences_before_exit"] = subprocess.run(
                ["defaults", "delete", domain], stdout=log, stderr=subprocess.STDOUT).returncode
        try:
            with (output / "fixture.log").open("xb") as log:
                process = subprocess.Popen([str(binary), "native-design"], env=environment,
                                           stdout=log, stderr=subprocess.STDOUT)
                entry["fixture_pid"] = process.pid
                deadline = time.monotonic() + 45
                while not ready.exists():
                    if process.poll() is not None:
                        raise RuntimeError("Fixture exits before capture readiness")
                    if time.monotonic() > deadline:
                        raise TimeoutError("Fixture capture readiness timed out")
                    time.sleep(0.05)
                metadata = json.loads(ready.read_text())
                if metadata["window_frame"] != [48, 72, 836, 900] or metadata["content_bounds"][2:] != [836, 900]:
                    raise RuntimeError("Fixture does not honor the fixed narrow capture size")
                if metadata["effective_dark"] != (settings.get("PERCH_STYLE_DARK") == "1"):
                    raise RuntimeError("Fixture appearance differs from requested scene")
                if metadata["large_type"] != (settings.get("PERCH_STYLE_LARGE_TYPE") == "1"):
                    raise RuntimeError("Fixture capture type size differs from requested scene")
                if metadata["locale"] != settings.get("PERCH_STYLE_LOCALE", "zh-Hans"):
                    raise RuntimeError("Fixture capture locale differs from requested scene")
                entry["window"] = metadata
                shutil.copyfile(ready, output / "window.json")
                wrapper = "const result=require('child_process').spawnSync('/usr/sbin/screencapture',process.argv.slice(1),{stdio:'inherit'});process.exit(result.status??1)"
                command = [str(node), "-e", wrapper, "--", "-x", "-o", "-t", "png", "-l",
                           str(metadata["window_number"]), str(screenshot)]
                entry["screenshot_command"] = command
                entry["fixed_settle_seconds_after_ready"] = 5
                time.sleep(5)
                with (output / "screencapture.log").open("xb") as log:
                    entry["capture_exit"] = subprocess.run(command, env=environment, stdout=log,
                                                            stderr=subprocess.STDOUT, timeout=15).returncode
                if entry["capture_exit"] != 0:
                    raise RuntimeError("Existing recording chain failed; no fallback")
                payload = screenshot.read_bytes()
                if payload[:8] != b"\x89PNG\r\n\x1a\n" or payload[12:16] != b"IHDR":
                    raise RuntimeError("Recording chain did not return a PNG")
                dimensions = struct.unpack(">II", payload[16:24])
                scale = metadata["backing_scale"]
                if dimensions != (round(836 * scale), round(900 * scale)):
                    raise RuntimeError("Capture PNG dimensions differ from ready window")
                entry["png_dimensions"] = list(dimensions)
                entry["png_sha256"] = digest(screenshot)
                if process.poll() is not None:
                    raise RuntimeError("Fixture exits during capture")
        except BaseException as error:
            entry["error"] = {"type": type(error).__name__, "message": str(error)}
            raise
        finally:
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                entry["fixture_exit_after_cleanup"] = process.returncode
            with (output / "preferences-after.log").open("xb") as log:
                entry["preferences_after_exit"] = subprocess.run(
                    ["defaults", "delete", domain], stdout=log, stderr=subprocess.STDOUT).returncode
            entry["finished_at"] = datetime.now().astimezone().isoformat(timespec="milliseconds")
            write_json(output / "capture-receipt.json", entry)
    return entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host-app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scenes", nargs="+", choices=[*SCENES, "all"], default=["light"])
    arguments = parser.parse_args()
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    application = arguments.host_app.resolve(strict=True)
    binary = application / "Contents/MacOS/HostLifecycleChecks"
    information = application / "Contents/Info.plist"
    domain = plistlib.loads(information.read_bytes())["CFBundleIdentifier"]
    if not domain.startswith("dev.agentworkbench.hostqa."):
        raise RuntimeError("Only existing offline HostLifecycleChecks fixture apps are accepted")
    selected_node = os.environ.get("PERCH_STYLE_CAPTURE_NODE") or shutil.which("node")
    if selected_node is None:
        raise RuntimeError("Existing Node recording driver is absent; no fallback")
    node = Path(selected_node).resolve(strict=True)
    selected = list(SCENES) if "all" in arguments.scenes else arguments.scenes
    if len(selected) != len(set(selected)):
        raise RuntimeError("Duplicate narrow scenes are not accepted")
    manifest = {"schema_version": 1, "started_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                "binary_sha256": digest(binary), "info_plist_sha256": digest(information),
                "capture_script_sha256": digest(Path(__file__)), "node_sha256": digest(node),
                "fixture_domain": domain, "permission_changes": False, "fallback": False,
                "fixture_state": "existing PERCH_STYLE_CAPTURE stopped fixture", "scenes": {}}
    try:
        for name in selected:
            entries = [capture(binary, domain, node, output / name / f"repeat-{repeat}", SCENES[name])
                       for repeat in (1, 2)]
            manifest["scenes"][name] = {"captures": entries,
                                       "PNG_bytes_identical": entries[0]["png_sha256"] == entries[1]["png_sha256"]}
            if entries[0]["window"]["window_frame"] != entries[1]["window"]["window_frame"]:
                raise RuntimeError(f"{name}: fixture window moved between repeats")
            if not manifest["scenes"][name]["PNG_bytes_identical"]:
                raise RuntimeError(f"{name}: zero-tolerance PNG stability failed")
        if digest(binary) != manifest["binary_sha256"] or digest(information) != manifest["info_plist_sha256"]:
            raise RuntimeError("Fixture app changed during capture")
        manifest["capture_verdict"] = "PASS_BYTES"
    except BaseException as error:
        manifest["capture_verdict"] = "FAIL"
        manifest["error"] = {"type": type(error).__name__, "message": str(error)}
        raise
    finally:
        manifest["finished_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
        write_json(output / "manifest.json", manifest)
    print(json.dumps({"scenes": len(selected), "capture_verdict": "PASS_BYTES"}))


if __name__ == "__main__":
    main()
