#!/usr/bin/env python3
"""Smoke-test the shipped SwiftUI App/WindowGroup entry point in an empty isolated domain.

HostLifecycleChecks uses its own AppKit entry point and cannot catch crashes while
SwiftUI creates the production window and materializes its NSToolbar items.
This checks process survival only; startup ownership and session recovery have
separate lifecycle/connection checks. No hosts, credentials, or user data are used.
"""
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=pathlib.Path("build/Perch.app"))
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    domain = "dev.agentworkbench.hostqa.launch." + uuid.uuid4().hex
    support = pathlib.Path.home() / "Library/Application Support" / domain
    saved_state = pathlib.Path.home() / "Library/Saved Application State" / (domain + ".savedState")
    result = {"scope": "isolated production WindowGroup cold launch; no remote acceptance"}
    try:
        with tempfile.TemporaryDirectory(prefix="perch-launch-") as folder:
            app = pathlib.Path(folder) / "Perch Launch Check.app"
            shutil.copytree(args.app.resolve(), app)
            info = app / "Contents/Info.plist"
            metadata = plistlib.loads(info.read_bytes())
            result["revision"] = metadata.get("PerchSourceRevision", "unknown")
            metadata["CFBundleIdentifier"] = domain
            metadata["CFBundleName"] = "Perch Launch Check"
            info.write_bytes(plistlib.dumps(metadata))
            subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)],
                           check=True, capture_output=True, timeout=30)
            binary = app / "Contents/MacOS" / metadata["CFBundleExecutable"]
            with (out / "console.log").open("w") as log:
                process = subprocess.Popen([str(binary)], stdout=log, stderr=subprocess.STDOUT)
                try:
                    # The appearance transaction is asynchronous; a successful spawn
                    # does not establish that the toolbar/window finished mounting.
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        if process.poll() is not None:
                            raise RuntimeError(f"Production app exited during launch ({process.returncode})")
                        time.sleep(0.25)
                    result["passed"] = True
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
    except Exception as error:
        result.update(passed=False, error=str(error))
    finally:
        subprocess.run(["defaults", "delete", domain], capture_output=True, timeout=10)
        shutil.rmtree(support, ignore_errors=True)
        shutil.rmtree(saved_state, ignore_errors=True)
        (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0 if result.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
