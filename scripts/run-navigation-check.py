#!/usr/bin/env python3
"""Supervise the isolated fixture; process exit alone never counts as acceptance."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("mode", choices=["claude", "assistant-rows", "user-rows", "paragraphs", "fast-scroll", "reading", "click", "scroll", "soak", "anchor", "interactions", "search", "roundtrip", "turns", "image", "disclosure"])
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--app", type=Path, help="Use a separately built A/B fixture app")
parser.add_argument("--seconds", type=int, default=1260)
parser.add_argument("--switches", type=int, default=40)
parser.add_argument("--recreate", action="store_true")
parser.add_argument("--scroll-step-points", type=float, default=0,
                    help="Use 1200 small scroll steps instead of the whole-document sweep")
parser.add_argument("--disclosure-context", action="store_true")
parser.add_argument("--scroll-reversal", action="store_true")
parser.add_argument("--assert-atomic-disclosure", action="store_true")
parser.add_argument("--full-content", action="store_true")
parser.add_argument("--long-output-variant", choices=["inline", "viewport"], default="viewport")
parser.add_argument("--output-lines", type=int, default=2400)
parser.add_argument("--output-shape", choices=["lines", "wrapped-line"], default="lines")
parser.add_argument("--scroll-hz", type=float, default=120)
args = parser.parse_args()
if not math.isfinite(args.scroll_hz) or args.scroll_hz <= 0:
    parser.error("--scroll-hz must be finite and positive")
if args.output_lines < 100:
    parser.error("--output-lines must be at least 100")
if args.scroll_step_points < 0:
    parser.error("--scroll-step-points must be nonnegative")
if args.scroll_reversal and args.scroll_step_points <= 0:
    parser.error("--scroll-reversal requires positive --scroll-step-points")
root = Path(__file__).resolve().parent.parent
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
app = args.app.resolve() if args.app else root / "build/Navigation Preview.app"
binary = app / "Contents/MacOS/NavigationPreview"
environment = dict(os.environ, NAVIGATION_AUTORUN=args.mode, NAVIGATION_TURNS="200", NAVIGATION_SCROLL_HZ=str(args.scroll_hz),
                   NAVIGATION_AUTOQUIT="1", NAVIGATION_RESULTS=str(output),
                   NAVIGATION_SWITCHES=str(args.switches),
                   NAVIGATION_SOAK_SECONDS=str(args.seconds),
                   NAVIGATION_RECREATE="1" if args.recreate else "0",
                   NAVIGATION_SCROLL_REVERSAL="1" if args.scroll_reversal else "0",
                   NAVIGATION_DISCLOSURE_CONTEXT="1" if args.disclosure_context else "0",
                   NAVIGATION_ASSERT_ATOMIC_DISCLOSURE="1" if args.assert_atomic_disclosure else "0",
                   NAVIGATION_FULL_DISCLOSURE="1" if args.full_content else "0",
                   NAVIGATION_LONG_OUTPUT_VARIANT=args.long_output_variant,
                   NAVIGATION_OUTPUT_LINES=str(args.output_lines),
                   NAVIGATION_OUTPUT_SHAPE=args.output_shape)
environment.pop("NAVIGATION_SCROLL_STEP_POINTS", None)
if args.scroll_step_points:
    environment["NAVIGATION_SCROLL_STEP_POINTS"] = str(args.scroll_step_points)
timeout = args.seconds + 120 if args.mode == "soak" else 120
record = {"status": "starting", "mode": args.mode, "timeout_s": timeout,
          "configuration": {key: value for key, value in environment.items() if key.startswith("NAVIGATION_")},
          "build": json.loads((app / "Contents/Resources/build.json").read_text()),
          "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}


def save():
    temporary = output / "supervisor.tmp"
    temporary.write_text(json.dumps(record, indent=2))
    temporary.replace(output / "supervisor.json")


save()
with (output / "process.log").open("w") as log:
    child = subprocess.Popen([str(binary)], cwd=root, env=environment,
                             stdout=log, stderr=subprocess.STDOUT)
    record.update(status="running", pid=child.pid)
    save()
    print(f"fixture pid={child.pid}; report={output}", flush=True)
    started = time.monotonic()
    try:
        code = child.wait(timeout=timeout)
        record.update(status="exited", exit_code=code)
    except subprocess.TimeoutExpired:
        child.terminate()
        try:
            code = child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            code = child.wait()
        record.update(status="timed_out", exit_code=code)
    record["elapsed_s"] = time.monotonic() - started
    result_path = output / "result.json"
    result = json.loads(result_path.read_text()) if result_path.exists() else {}
    record["passed"] = record["status"] == "exited" and code == 0 and result.get("status") == "passed"
    if not result:
        record["failure"] = "missing final report"
    save()
    print(json.dumps(record), flush=True)
    raise SystemExit(0 if record["passed"] else 1)
