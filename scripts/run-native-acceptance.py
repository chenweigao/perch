#!/usr/bin/env python3
"""Run the real workbench offline; optionally capture short, bounded Instruments traces."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--app", type=Path, help="Use a separately built fixed A/B app")
parser.add_argument("--capture", choices=["none", "cpu", "frames"], default="none")
parser.add_argument("--positive-control", action="store_true", help="Inject one 120ms main-thread stop in the isolated frames run")
parser.add_argument("--mode", choices=["all", "joint", "switching", "paging", "dashboard"], default="all")
parser.add_argument("--seconds", type=int, default=24, help="Duration of the paced joint scenario")
args = parser.parse_args()
if args.seconds <= 0:
    parser.error("--seconds must be positive")
if args.mode == "joint" and (args.capture == "frames" or (args.capture == "cpu" and args.seconds > 30)):
    parser.error("joint supports uncaptured runs or CPU captures of at most 30 seconds")
if args.positive_control and args.capture != "frames":
    parser.error("--positive-control requires --capture frames")
root = Path(__file__).resolve().parent.parent
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
app = args.app.resolve() if args.app else root / "build/Perch Acceptance.app"
binary = app / "Contents/MacOS/NativeAcceptance"
manifest = json.loads((app / "Contents/Resources/build.json").read_text())
manifest.update(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), capture=args.capture,
                mode="frames" if args.capture == "frames" else args.mode)
env = dict(os.environ, PERCH_ACCEPTANCE_MODE=manifest["mode"], PERCH_ACCEPTANCE_RESULTS=str(out))
env["PERCH_ACCEPTANCE_KEEP_OPEN"] = "0"
env["PERCH_ACCEPTANCE_JOINT_SECONDS"] = str(args.seconds)
env["PERCH_ACCEPTANCE_STALL"] = "1" if args.positive_control else "0"
manifest["positive_control"] = args.positive_control
manifest["joint_seconds"] = args.seconds if args.mode == "joint" else None
command = [str(binary)]
if args.capture != "none":
    command = ["xcrun", "xctrace", "record", "--template",
               "Animation Hitches" if args.capture == "frames" else "Time Profiler",
               "--instrument", "Points of Interest", "--time-limit", "12s" if args.capture == "frames" else "60s",
               "--output", str(out / "run.trace")]
    for key in ["PERCH_ACCEPTANCE_MODE", "PERCH_ACCEPTANCE_RESULTS", "PERCH_ACCEPTANCE_STALL", "PERCH_ACCEPTANCE_KEEP_OPEN", "PERCH_ACCEPTANCE_JOINT_SECONDS"]:
        command += ["--env", f"{key}={env[key]}"]
    command += ["--launch", "--", str(binary)]
started = time.monotonic()
with (out / "process.log").open("w") as log:
    process = subprocess.Popen(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT,
                               start_new_session=True)
    manifest["supervisor_pid"] = process.pid
    try:
        manifest["exit_code"] = process.wait(timeout=95 if args.capture != "none" else max(60, args.seconds + 60))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        manifest["failure"] = "recording or fixture timed out; incomplete trace is not acceptance"
manifest["elapsed_s"] = time.monotonic() - started
result = json.loads((out / "result.json").read_text()) if (out / "result.json").exists() else {}
manifest["behavior_passed"] = result.get("status") == "passed"


def export(arguments, filename):
    subprocess.run(["xcrun", "xctrace", "export", "--input", str(out / "run.trace"), *arguments,
                    "--output", str(out / filename)], check=True, capture_output=True, timeout=40)


try:
    if args.capture != "none" and "failure" not in manifest:
        export(["--toc"], "toc.xml")
        toc = ET.parse(out / "toc.xml")
        schemas = {t.attrib["schema"] for t in toc.findall(".//table")}
        wanted = ["os-signpost", "time-profile"] if args.capture == "cpu" else [
            "os-signpost", "hitches-updates", "hitches", "hitches-frame-lifetimes", "display-vsyncs-interval"]
        manifest["missing_schemas"] = sorted(set(wanted) - schemas)
        for schema in wanted:
            if schema in schemas:
                export(["--xpath", f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], schema + ".xml")
        # Presence of a .trace or empty schema never establishes usable frame data.
        manifest["trace_exported"] = not manifest["missing_schemas"]
        if args.capture == "frames" and manifest["trace_exported"]:
            summary = subprocess.run(["python3", str(root / "scripts/summarize-native-frames.py"), str(out)],
                                     capture_output=True, text=True, timeout=20)
            (out / "frame-summary.json").write_text(summary.stdout)
            summary.check_returncode()
            frames = json.loads(summary.stdout)
            manifest["app_frame_events_verified"] = frames["status"] == "usable_frame_events"
            if not manifest["app_frame_events_verified"]:
                manifest["failure"] = "no usable app-owned frame events; this capture is unverified"
            if args.positive_control and not frames["positive_control_detected"]:
                manifest["failure"] = "known main-thread stall was not reported as an app hitch; zero-hitch results cannot certify smoothness"
except (subprocess.SubprocessError, OSError, ET.ParseError) as error:
    manifest["failure"] = str(error)
(out / "manifest.json").write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2))
passed = manifest["behavior_passed"] and "failure" not in manifest and manifest.get("exit_code") in (0, 54)
if args.capture == "none":
    passed = passed and manifest.get("exit_code") == 0
if args.capture != "none":
    passed = passed and manifest.get("trace_exported", False)
if args.capture == "frames":
    passed = passed and manifest.get("app_frame_events_verified", False)
raise SystemExit(0 if passed else 1)
