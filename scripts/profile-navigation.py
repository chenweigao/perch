#!/usr/bin/env python3
"""Record one fixed, offline native scenario using Xcode Instruments."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("mode", choices=["reading", "scroll", "small-scroll", "roundtrip", "interactions", "anchor", "turns", "resource", "soak"])
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--app", type=Path, help="Use a fixed A/B fixture build")
parser.add_argument("--image-fixture", type=Path, help="Include the same local attachment in each fixture history")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
app = args.app.resolve() if args.app else root / "build/Navigation Preview.app"
binary = app / "Contents/MacOS/NavigationPreview"
metadata = json.loads((app / "Contents/Resources/build.json").read_text())
metadata.update(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                mode=args.mode, template="Time Profiler", history_turns=200, sessions=500)
if args.image_fixture:
    metadata["image_sha256"] = hashlib.sha256(args.image_fixture.read_bytes()).hexdigest()
(out / "manifest.json").write_text(json.dumps(metadata, indent=2))
env = {"NAVIGATION_AUTORUN": "scroll" if args.mode == "small-scroll" else args.mode,
       "NAVIGATION_TURNS": "200", "NAVIGATION_SESSIONS": "500", "NAVIGATION_SWITCHES": "20",
       "NAVIGATION_AUTOQUIT": "1", "NAVIGATION_RESULTS": str(out),
       "NAVIGATION_WINDOW_SECONDS": "8", "NAVIGATION_SOAK_SECONDS": "60"}
if args.mode == "small-scroll":
    env["NAVIGATION_SCROLL_STEP_POINTS"] = "8"
if args.image_fixture:
    env["NAVIGATION_IMAGE_FIXTURE"] = str(args.image_fixture.resolve())
command = ["xcrun", "xctrace", "record", "--template", "Time Profiler", "--time-limit", "180s",
           "--output", str(out / "run.trace")]
for key, value in env.items():
    command.extend(["--env", f"{key}={value}"])
command.extend(["--launch", "--", str(binary)])
with (out / "record.log").open("w") as log:
    recording = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
# xctrace returns 54 when a fixture assertion fails, but still saves its trace.
if recording.returncode not in (0, 54):
    recording.check_returncode()
metadata["record_exit_code"] = recording.returncode
(out / "manifest.json").write_text(json.dumps(metadata, indent=2))
subprocess.run(["xcrun", "xctrace", "export", "--input", str(out / "run.trace"), "--toc",
                "--output", str(out / "toc.xml")], check=True, capture_output=True)
subprocess.run(["xcrun", "xctrace", "export", "--input", str(out / "run.trace"),
                "--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
                "--output", str(out / "cpu.xml")], check=True, capture_output=True)
with (out / "cpu-summary.json").open("w") as report:
    subprocess.run(["python3", str(root / "scripts/summarize-time-profile.py"),
                    str(out / "cpu.xml"), "--after", "4"], stdout=report, check=True)
result = json.loads((out / "result.json").read_text())
print(args.mode, result.get("status"), result.get("error", ""), flush=True)
# A saved trace alone is not functional acceptance.
raise SystemExit(0 if result.get("status") == "passed" else 1)
