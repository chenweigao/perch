#!/usr/bin/env python3
"""After scripts/build.sh, check the production model without SSH or real preferences."""
import argparse
import pathlib
import platform
import plistlib
import shutil
import subprocess
import tempfile
import uuid

PHASES = ["seed", "restart", "removal", "connection-controls", "connection-restart", "architecture", "interactions", "stream-reveal", "git-write", "reading-design", "reading-controls", "goal-header", "reading-canvas", "sidebar-scroll", "activity-bar", "reply-selection", "frame-hitch", "workspace-upgrade", "file-reader", "code-reader", "workflow-polish", "document-reading", "task-context"]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--release", action="store_true", help="Compile fixtures with optimization for component timing")
parser.add_argument("--phase", action="append", choices=PHASES, help="Run only the named phase(s)")
parser.add_argument("--preview-file-reader", action="store_true", help="Keep the isolated file-reader fixture open for 120 seconds after checks")
args = parser.parse_args()
if args.preview_file_reader:
    args.phase = [phase for phase in args.phase or [] if phase != "file-reader"] + ["file-reader"]

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
               "GhosttyTerminal", "GhosttyKit", "MSDisplayLink", "SwiftMath"]:
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
    subprocess.run([str(ROOT / "scripts/prepare-highlight.sh"), str(app / "Contents/Resources")], check=True)
    compiled = work / "compiled"
    subprocess.run([
        "swiftc", *(["-O", "-whole-module-optimization"] if args.release else ["-Onone"]), "-swift-version", "5", "-parse-as-library",
        "-target", platform.machine() + "-apple-macosx26.0", *includes,
        *map(str, sources), *map(str, sorted((ROOT / "Tests/HostLifecycleChecks").glob("*.swift"))),
        *map(str, objects), str(ghostty / "libghostty.a"), "-lc++",
        "-framework", "Carbon", "-framework", "Metal", "-framework", "QuartzCore",
        "-o", str(compiled),
    ], cwd=ROOT, check=True)
    # Stage a fresh executable inode before signing the isolated app bundle.
    shutil.copy2(compiled, executable)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    try:
        for phase in args.phase or PHASES:
            preview = args.preview_file_reader and phase == "file-reader"
            if preview:
                print(f"File reader preview app: {app}", flush=True)
            subprocess.run([str(executable), phase, *(["preview"] if preview else [])],
                           check=True, timeout=150 if preview else 60)
    finally:
        subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)
        shutil.rmtree(pathlib.Path.home() / "Library/Application Support" / DOMAIN, ignore_errors=True)
