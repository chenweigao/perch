#!/usr/bin/env python3
"""Check the production summary queue with injected responses and isolated preferences."""
import pathlib
import platform
import plistlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(subprocess.check_output(
    ["swift", "build", "--build-system", "native", "-c", "release", "--show-bin-path"], cwd=ROOT, text=True).strip())
DOMAIN = "dev.agentworkbench.summaryqa." + uuid.uuid4().hex
includes = ["-I", str(BIN / "Modules")]
for path in ["swift-markdown/Sources/CAtomic/include", "swift-cmark/src/include", "swift-cmark/extensions/include"]:
    includes += ["-I", str(ROOT / ".build/checkouts" / path)]
objects = []
for target in ["WorkbenchCore", "Markdown", "CAtomic", "cmark_gfm", "cmark_gfm_extensions"]:
    objects += sorted((BIN / (target + ".build")).glob("*.o"))
with tempfile.TemporaryDirectory(prefix="perch-summary-check-", dir=ROOT / ".build") as folder:
    work = pathlib.Path(folder)
    app = work / "SummaryLifecycleChecks.app"
    executable = app / "Contents/MacOS/SummaryLifecycleChecks"
    executable.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": DOMAIN, "CFBundleName": "Summary Lifecycle Checks",
        "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    subprocess.run([
        "swiftc", "-Onone", "-swift-version", "5", "-parse-as-library",
        "-target", platform.machine() + "-apple-macosx14.0", *includes,
        str(ROOT / "Sources/AgentWorkbench/ActivitySummarySettings.swift"),
        str(ROOT / "Sources/AgentWorkbench/ActivitySummaryController.swift"),
        str(ROOT / "Tests/SummaryLifecycleChecks/App.swift"),
        *map(str, objects),
        "-o", str(work / "compiled"),
    ], cwd=ROOT, check=True)
    shutil.copy2(work / "compiled", executable)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    try:
        subprocess.run([str(executable)], check=True, timeout=30)
    finally:
        subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)
