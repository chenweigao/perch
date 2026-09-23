#!/usr/bin/env python3
"""After scripts/build.sh, check the production model without SSH or real preferences."""
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
DOMAIN = "dev.agentworkbench.hostqa." + uuid.uuid4().hex
includes = ["-I", str(BIN / "Modules")]
for path in ["swift-markdown/Sources/CAtomic/include", "swift-cmark/src/include", "swift-cmark/extensions/include"]:
    includes += ["-I", str(ROOT / ".build/checkouts" / path)]
ghostty = ROOT / ".build/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64"
includes += ["-I", str(ghostty / "Headers")]
objects = []
for target in ["WorkbenchCore", "Markdown", "CAtomic", "cmark_gfm", "cmark_gfm_extensions",
               "GhosttyTerminal", "GhosttyKit", "MSDisplayLink"]:
    objects += sorted((BIN / (target + ".build")).glob("*.o"))
sources = sorted(path for path in (ROOT / "Sources/AgentWorkbench").glob("*.swift")
                 if path.name != "WorkbenchApp.swift")

with tempfile.TemporaryDirectory(prefix="perch-host-check-", dir=ROOT / ".build") as folder:
    work = pathlib.Path(folder)
    app = work / "HostLifecycleChecks.app"
    executable = app / "Contents/MacOS/HostLifecycleChecks"
    executable.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": DOMAIN, "CFBundleName": "Host Lifecycle Checks",
        "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    compiled = work / "compiled"
    subprocess.run([
        "swiftc", "-Onone", "-swift-version", "5", "-parse-as-library",
        "-target", platform.machine() + "-apple-macosx14.0", *includes,
        *map(str, sources), str(ROOT / "Tests/HostLifecycleChecks/App.swift"),
        *map(str, objects), str(ghostty / "libghostty.a"), "-lc++",
        "-framework", "Carbon", "-framework", "Metal", "-framework", "QuartzCore",
        "-o", str(compiled),
    ], cwd=ROOT, check=True)
    # Stage a fresh executable inode before signing the isolated app bundle.
    shutil.copy2(compiled, executable)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    try:
        for phase in ["seed", "restart", "removal"]:
            subprocess.run([str(executable), phase], check=True, timeout=30)
    finally:
        subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)
        shutil.rmtree(pathlib.Path.home() / "Library/Application Support" / DOMAIN, ignore_errors=True)
