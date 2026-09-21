#!/usr/bin/env python3
"""Supervise the isolated fixture; process exit alone never counts as acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("mode", choices=["reading", "click", "scroll", "soak"])
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--seconds", type=int, default=1260)
parser.add_argument("--switches", type=int, default=40)
parser.add_argument("--recreate", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
binary = root / "build/Navigation Preview.app/Contents/MacOS/NavigationPreview"
environment = dict(os.environ, NAVIGATION_AUTORUN=args.mode, NAVIGATION_TURNS="200",
                   NAVIGATION_AUTOQUIT="1", NAVIGATION_RESULTS=str(output),
                   NAVIGATION_SWITCHES=str(args.switches),
                   NAVIGATION_SOAK_SECONDS=str(args.seconds),
                   NAVIGATION_RECREATE="1" if args.recreate else "0")
timeout = args.seconds + 120 if args.mode == "soak" else 120
record = {"status": "starting", "mode": args.mode, "timeout_s": timeout,
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
