#!/usr/bin/env python3
"""Run offline functional checks with bounded commands and retained failure logs."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=["portable", "macos"])
    parser.add_argument("--output", type=Path, required=True, help="New directory for this run")
    args = parser.parse_args()
    if args.suite == "macos" and sys.platform != "darwin":
        parser.error("macos checks require a Mac with Xcode and an active GUI session")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    python = sys.executable
    if args.suite == "portable":
        commands = [
            ("bridge", [python, "-m", "unittest", "discover", "-s", "remote", "-p", "test_*.py"], 180),
            ("installer", [python, "-m", "unittest", "discover", "-s", "Tests/RemoteSetup"], 60),
            ("localization", [python, "scripts/check-localization.py"], 60),
            ("localization-tests", [python, "-m", "unittest", "discover", "-s", "Tests/Localization"], 60),
            ("acceptance-supervisor", [python, "-m", "unittest", "discover", "-s", "Tests/Performance"], 60),
        ]
    else:
        commands = [
            ("build", ["bash", "scripts/build.sh"], 1200),
            ("signature", ["codesign", "--verify", "--deep", "--strict", "build/Perch.app"], 60),
            ("workbench", ["swift", "run", "--build-system", "native", "-c", "release", "--skip-build", "WorkbenchChecks"], 120),
            ("connections", ["swift", "run", "--build-system", "native", "-c", "release", "--skip-build", "ConnectionChecks"], 120),
            ("composer", ["bash", "scripts/check-composer.sh"], 120),
            ("host-lifecycle", [python, "scripts/check-host-lifecycle.py"], 180),
            ("scroll-following", [python, "scripts/check-scroll-following.py"], 120),
            ("native-build", ["bash", "scripts/build-native-acceptance.sh"], 600),
        ]
        for mode in ["all", "switching", "dashboard", "joint"]:
            commands.append(("native-" + mode, [python, "scripts/run-native-acceptance.py",
                "--mode", mode, "--seconds", "60", "--output", str(out / ("native-" + mode))], 150))
        commands.append(("navigation-build", ["bash", "scripts/build-navigation-preview.sh"], 300))
        for mode in ["reading", "interactions", "roundtrip"]:
            commands.append(("navigation-" + mode, [python, "scripts/run-navigation-check.py",
                mode, "--output", str(out / ("navigation-" + mode))], 150))
    report = {"suite": args.suite, "scope": "offline synthetic checks; no SSH, real models or frame-rate certification",
              "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)), "checks": []}
    env = dict(os.environ)
    # A developer's optional live SSH target must never turn these into online checks.
    env.pop("WORKBENCH_LIVE_HOST", None)
    for name, command, timeout in commands:
        print("Running " + name, flush=True)
        started = time.monotonic()
        entry = {"name": name, "command": command, "log": name + ".log"}
        with (out / entry["log"]).open("w") as log:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                entry["exit_code"] = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                entry.update(exit_code=process.returncode, timed_out=True)
        entry["seconds"] = round(time.monotonic() - started, 2)
        entry["passed"] = entry["exit_code"] == 0 and not entry.get("timed_out")
        report["checks"].append(entry)
        report["status"] = "running" if entry["passed"] else "failed"
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        if not entry["passed"]:
            print((out / entry["log"]).read_text()[-12000:])
            return 1
    report["status"] = "passed"
    (out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Passed: " + str(out / "results.json"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
