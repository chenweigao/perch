#!/usr/bin/env python3
"""Check the shipped SwiftUI WindowGroup in five fresh, isolated preference domains.

AppKit toolbar installation can fail intermittently during cold launch. A fixture
with an AppKit entry point cannot exercise this production WindowGroup path.
No hosts, credentials or user workspace state are used.
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


def check_launch(source, out):
    out.mkdir()
    domain = "dev.agentworkbench.hostqa.launch." + uuid.uuid4().hex
    support = pathlib.Path.home() / "Library/Application Support" / domain
    saved_state = pathlib.Path.home() / "Library/Saved Application State" / (domain + ".savedState")
    try:
        with tempfile.TemporaryDirectory(prefix="perch-launch-") as folder:
            app = pathlib.Path(folder) / "Perch Launch Check.app"
            shutil.copytree(source, app)
            info = app / "Contents/Info.plist"
            metadata = plistlib.loads(info.read_bytes())
            revision = metadata.get("PerchSourceRevision", "unknown")
            metadata["CFBundleIdentifier"] = domain
            metadata["CFBundleName"] = "Perch Launch Check"
            info.write_bytes(plistlib.dumps(metadata))
            subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)],
                           check=True, capture_output=True, timeout=30)
            binary = app / "Contents/MacOS" / metadata["CFBundleExecutable"]
            with (out / "console.log").open("w") as log:
                process = subprocess.Popen([str(binary)], stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        if process.poll() is not None:
                            raise RuntimeError(f"Production app exited during launch ({process.returncode})")
                        time.sleep(0.25)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
            return revision
    finally:
        subprocess.run(["defaults", "delete", domain], capture_output=True, timeout=10)
        shutil.rmtree(support, ignore_errors=True)
        shutil.rmtree(saved_state, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=pathlib.Path("build/Perch.app"))
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    result = {"scope": "five isolated production WindowGroup cold launches; no remote acceptance",
              "completed_launches": 0}
    try:
        for index in range(1, 6):
            result["revision"] = check_launch(args.app.resolve(), out / f"launch-{index}")
            result["completed_launches"] = index
            print(f"Passed cold launch {index}/5", flush=True)
        result["passed"] = True
    except Exception as error:
        result.update(passed=False, error=str(error))
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0 if result.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
