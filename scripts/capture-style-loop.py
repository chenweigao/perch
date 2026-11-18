#!/usr/bin/env python3
"""Capture repeatable offline main-window and preview fixtures in a PerfRunner GUI job."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
PREVIEWS = {
    "workbench": ROOT / "build/Workbench Preview.app/Contents/MacOS/WorkbenchPreview",
    "sidebar": ROOT / "build/Sidebar Preview.app/Contents/MacOS/SidebarPreview",
    "composer": ROOT / "build/Composer Preview.app/Contents/MacOS/ComposerPreview",
}
VARIANTS = [("light", {}), ("dark", {"PERCH_STYLE_DARK": "1"}),
            ("english", {"PERCH_STYLE_LOCALE": "en"}),
            ("large-type", {"PERCH_STYLE_LARGE_TYPE": "1"})]
PREVIEW_VARIANTS = {
    "workbench": VARIANTS[:3],
    "sidebar": VARIANTS[:3],
    "composer": VARIANTS[:2],
}


def visible_png_pixels(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"Not a PNG: {path}")
    offset, compressed, header = 8, bytearray(), None
    while offset < len(data):
        length = int.from_bytes(data[offset:offset + 4], "big")
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            header = body
        elif kind == b"IDAT":
            compressed.extend(body)
        elif kind == b"IEND":
            break
    if header is None:
        raise ValueError(f"Missing PNG header: {path}")
    width, height = int.from_bytes(header[:4], "big"), int.from_bytes(header[4:8], "big")
    depth, color, interlace = header[8], header[9], header[12]
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
    if depth != 8 or channels is None or interlace != 0:
        raise ValueError(f"Unsupported PNG format depth={depth} color={color} interlace={interlace}: {path}")
    raw = zlib.decompress(bytes(compressed))
    stride = width * channels
    expected = height * (stride + 1)
    if len(raw) != expected:
        raise ValueError(f"Unexpected PNG scanline bytes {len(raw)} != {expected}: {path}")

    def paeth(a, b, c):
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        return a if pa <= pb and pa <= pc else b if pb <= pc else c

    rows, previous = [], bytearray(stride)
    cursor = 0
    for _ in range(height):
        filter_kind = raw[cursor]
        source = raw[cursor + 1:cursor + 1 + stride]
        cursor += stride + 1
        row = bytearray(stride)
        for x, value in enumerate(source):
            left = row[x - channels] if x >= channels else 0
            above = previous[x]
            upper_left = previous[x - channels] if x >= channels else 0
            predictor = {0: 0, 1: left, 2: above, 3: (left + above) // 2,
                         4: paeth(left, above, upper_left)}.get(filter_kind)
            if predictor is None:
                raise ValueError(f"Unsupported PNG filter {filter_kind}: {path}")
            row[x] = (value + predictor) & 255
        rows.append(row)
        previous = row
    visible = bytearray(width * height * 3)
    for y, row in enumerate(rows):
        for x in range(width):
            start = x * channels
            if color == 6:
                r, g, b, alpha = row[start:start + 4]
            elif color == 2:
                r, g, b, alpha = *row[start:start + 3], 255
            elif color == 4:
                r = g = b = row[start]
                alpha = row[start + 1]
            else:
                r = g = b = row[start]
                alpha = 255
            target = (y * width + x) * 3
            visible[target:target + 3] = bytes((component * alpha + 255 * (255 - alpha) + 127) // 255
                                               for component in (r, g, b))
    return (width, height), bytes(visible)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--host-app", type=Path, default=ROOT / ".local/style-loop/HostLifecycleChecks.app")
    parser.add_argument("--build-host", action="store_true")
    parser.add_argument("--build-previews", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    host_app = args.host_app.resolve()
    started = time.monotonic()
    manifest = {
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)),
        "boundary": "offline synthetic fixtures in a PerfRunner Aqua job; no user sessions or remote agents",
        "comparisons": [], "commands": [],
    }

    def run(name, command, *, env=None, timeout=180):
        log_path = out / "logs" / (name + ".log")
        log_path.parent.mkdir(exist_ok=True)
        merged_env = dict(os.environ)
        if env:
            merged_env.update(env)
        entry = {"name": name, "command": [str(part) for part in command], "log": str(log_path.relative_to(out))}
        manifest["commands"].append(entry)
        started_command = time.monotonic()
        with log_path.open("w") as log:
            log.write("Command: " + repr(command) + "\n")
            log.flush()
            result = subprocess.run(command, cwd=ROOT, env=merged_env, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        entry.update(exit_code=result.returncode, seconds=round(time.monotonic() - started_command, 3))
        if result.returncode:
            raise RuntimeError(f"{name} failed; see {log_path}")

    def screen_capture(name, arguments):
        node = os.environ.get("PERCH_STYLE_CAPTURE_NODE") or shutil.which("node")
        if node:
            script = ("const r=require('child_process').spawnSync('/usr/sbin/screencapture',"
                      "process.argv.slice(1),{stdio:'inherit'});process.exit(r.status??1)")
            run(name, [node, "-e", script, "--", *arguments], timeout=15)
        else:
            run(name, ["/usr/sbin/screencapture", *arguments], timeout=15)

    def clean_preferences(binary):
        app = binary.parents[2]
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        domain = info["CFBundleIdentifier"]
        subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(Path.home() / "Library/Application Support" / domain, ignore_errors=True)

    def capture(name, binary, arguments, settings, target):
        target.mkdir(parents=True)
        output = target / "capture.png"
        ready = Path(str(output) + ".ready.json")
        clean_preferences(binary)
        env = dict(os.environ, PERCH_STYLE_CAPTURE=str(output), **settings)
        log_path = out / "logs" / (name + ".log")
        log_path.parent.mkdir(exist_ok=True)
        entry = {"name": name, "command": [str(binary), *arguments],
                 "environment": {"PERCH_STYLE_CAPTURE": str(output), **settings},
                 "log": str(log_path.relative_to(out))}
        manifest["commands"].append(entry)
        started_command = time.monotonic()
        with log_path.open("w") as log:
            process = subprocess.Popen([binary, *arguments], cwd=ROOT, env=env,
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 30
                while not ready.exists():
                    if process.poll() is not None:
                        raise RuntimeError(f"{name} exited before capture readiness; see {log_path}")
                    if time.monotonic() > deadline:
                        raise RuntimeError(f"{name} did not become capture-ready; see {log_path}")
                    time.sleep(0.1)
                metadata = json.loads(ready.read_text())
                expected_dark = settings.get("PERCH_STYLE_DARK") == "1"
                if metadata.get("effective_dark") != expected_dark:
                    raise RuntimeError(f"{name} appearance mismatch: {metadata}")
                (target / "window.json").write_text(json.dumps(metadata, indent=2) + "\n")
                screen_capture(name + "-screencapture", ["-x", "-o", "-t", "png",
                    "-l", str(metadata["window_number"]), output])
                if not output.is_file() or output.stat().st_size == 0:
                    raise RuntimeError(f"{name} produced no screenshot")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                entry.update(exit_code=process.returncode, seconds=round(time.monotonic() - started_command, 3))
                clean_preferences(binary)
                shutil.rmtree(Path("/tmp/perch-style-capture"), ignore_errors=True)

    try:
        if args.build_host:
            run("build-host", ["python3", "scripts/check-host-lifecycle.py", "--app", host_app, "--build-only"], timeout=900)
        if args.build_previews:
            for name in PREVIEWS:
                run("build-" + name, ["bash", f"scripts/build-{name}-preview.sh"], timeout=900)
        main_binary = host_app / "Contents/MacOS/HostLifecycleChecks"
        for variant, settings in VARIANTS:
            for repeat in (1, 2):
                capture(f"main-{variant}-repeat-{repeat}", main_binary, ["native-design"], settings,
                        out / f"main-{variant}" / f"repeat-{repeat}")
        for scenario in ("find", "inspector-closed", "dashboard", "scroll"):
            for repeat in (1, 2):
                capture(f"main-{scenario}-repeat-{repeat}", main_binary, ["native-design"],
                        {"PERCH_STYLE_SCENARIO": scenario}, out / f"main-{scenario}" / f"repeat-{repeat}")
        for repeat in (1, 2):
            capture(f"main-find-dark-repeat-{repeat}", main_binary, ["native-design"],
                    {"PERCH_STYLE_SCENARIO": "find", "PERCH_STYLE_DARK": "1"},
                    out / "main-find-dark" / f"repeat-{repeat}")
        for name, binary in PREVIEWS.items():
            for variant, settings in PREVIEW_VARIANTS[name]:
                for repeat in (1, 2):
                    arguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
                    if name == "workbench":
                        arguments += ["-scenario", "日常"]
                    capture(f"{name}-{variant}-repeat-{repeat}", binary, arguments, settings,
                            out / f"{name}-{variant}" / f"repeat-{repeat}")
        for repeat in (1, 2):
            binary = PREVIEWS["workbench"]
            arguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
                         "-scenario", "首次使用"]
            capture(f"workbench-empty-light-repeat-{repeat}", binary, arguments, {},
                    out / "workbench-empty-light" / f"repeat-{repeat}")
        groups = [path for path in out.iterdir() if path.is_dir() and (path / "repeat-1").exists()]
        for group in sorted(groups):
            a, b = group / "repeat-1/capture.png", group / "repeat-2/capture.png"
            entry = {"group": group.name, "first_exists": a.exists(), "second_exists": b.exists()}
            if a.exists() and b.exists():
                entry["first_sha256"] = hashlib.sha256(a.read_bytes()).hexdigest()
                entry["second_sha256"] = hashlib.sha256(b.read_bytes()).hexdigest()
                entry["byte_identical"] = a.read_bytes() == b.read_bytes()
                if entry["byte_identical"]:
                    header = a.read_bytes()[16:24]
                    entry["dimensions"] = [int.from_bytes(header[:4], "big"), int.from_bytes(header[4:8], "big")]
                    entry["identical"] = True
                    entry["comparison"] = "byte-identical PNG; pixels necessarily identical"
                else:
                    first_size, first_pixels = visible_png_pixels(a)
                    second_size, second_pixels = visible_png_pixels(b)
                    entry["dimensions"] = list(first_size)
                    entry["identical"] = first_size == second_size and first_pixels == second_pixels
                    entry["comparison"] = "decoded pixels composited over white; invisible RGB excluded"
            else:
                entry["identical"] = False
            manifest["comparisons"].append(entry)
            if not entry["identical"]:
                raise RuntimeError(f"Unstable capture: {group.name}")
        manifest["status"] = "passed"
    except Exception as error:
        manifest["status"] = "failed"
        manifest["error"] = str(error)
        raise
    finally:
        manifest["seconds"] = round(time.monotonic() - started, 3)
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps({"status": manifest["status"], "output": str(out),
                          "comparisons": len(manifest["comparisons"]), "seconds": manifest["seconds"]}, indent=2))


if __name__ == "__main__":
    main()
