#!/usr/bin/env python3
"""After scripts/build.sh, check the production model without SSH or real preferences."""
import argparse
import faulthandler
import os
import pathlib
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

PHASES = ["startup", "seed", "restart", "removal", "connection-controls", "connection-restart", "architecture", "interactions", "streaming-rendering", "streaming-cadence", "git-write", "reading-design", "reading-controls", "goal-header", "reading-canvas", "sidebar-scroll", "activity-bar", "reply-selection", "frame-hitch", "workspace-upgrade", "file-reader", "code-reader", "workflow-polish", "document-reading", "task-context", "task-detail", "task-summary", "native-design"]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=pathlib.Path, help="Build the fixture at this path, or reuse it when already compiled")
parser.add_argument("--build-only", action="store_true", help="Build --app without running any phases")
parser.add_argument("--preview-reading-design", action="store_true", help="Keep a standalone native reading review app")
parser.add_argument("--release", action="store_true", help="Compile fixtures with optimization for component timing")
parser.add_argument("--phase", action="append", choices=PHASES, help="Run only the named phase(s)")
parser.add_argument("--preview-file-reader", action="store_true", help="Keep the isolated file-reader fixture open for 120 seconds after checks")
parser.add_argument("--preview-document-reader", action="store_true", help="Keep the isolated document reader open for 120 seconds")
parser.add_argument("--preview-native-design", action="store_true", help="Build a persistent, isolated production-workspace preview and run its checks")
args = parser.parse_args()
if args.preview_file_reader:
    args.phase = [phase for phase in args.phase or [] if phase != "file-reader"] + ["file-reader"]
if args.preview_document_reader:
    args.phase = [phase for phase in args.phase or [] if phase != "document-reading"] + ["document-reading"]
if args.preview_native_design:
    args.phase = [phase for phase in args.phase or [] if phase != "native-design"] + ["native-design"]

ROOT = pathlib.Path(__file__).resolve().parents[1]
app = args.app.resolve() if args.app else None
reuse = bool(app and (app / "Contents/MacOS/HostLifecycleChecks").is_file())
if args.build_only and (app is None or reuse or args.phase):
    parser.error("--build-only requires a new --app path and no --phase")
DOMAIN = "dev.agentworkbench.hostqa." + uuid.uuid4().hex
if reuse:
    metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    DOMAIN = metadata["CFBundleIdentifier"]

with tempfile.TemporaryDirectory(prefix="perch-host-check-", dir=None if reuse else ROOT / ".build") as folder:
    work = pathlib.Path(folder)
    if app is None:
        app = work / "HostLifecycleChecks.app"
    executable = app / "Contents/MacOS/HostLifecycleChecks"
    started = time.monotonic()
    if not reuse:
        BIN = pathlib.Path(subprocess.check_output(
            ["swift", "build", "--build-system", "native", "-c", "release", "--show-bin-path"], cwd=ROOT, text=True).strip())
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
        executable.parent.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": DOMAIN, "CFBundleName": "Host Lifecycle Checks",
            "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL", "LSUIElement": True,
        }))
        subprocess.run([str(ROOT / "scripts/prepare-highlight.sh"), str(app / "Contents/Resources")], check=True)
        # Dynamic phase labels use the same catalogs as the production app.
        for locale in (ROOT / "Resources/Localization").glob("*.lproj"):
            shutil.copytree(locale, app / "Contents/Resources" / locale.name, dirs_exist_ok=True)
        compiled = work / "compiled"
        print("Compiling host lifecycle fixture", flush=True)
        subprocess.run([
            "swiftc", "-j", str(os.cpu_count() or 4), *(["-O", "-whole-module-optimization"] if args.release else ["-Onone"]), "-swift-version", "5", "-parse-as-library",
            "-target", platform.machine() + "-apple-macosx26.0", *includes,
            *map(str, sources), *map(str, sorted((ROOT / "Tests/HostLifecycleChecks").glob("*.swift"))),
            *map(str, objects), str(ghostty / "libghostty.a"), "-lc++",
            "-framework", "Carbon", "-framework", "Metal", "-framework", "QuartzCore",
            "-o", str(compiled),
        ], cwd=ROOT, check=True)
        # Stage a fresh executable inode before signing the isolated app bundle.
        shutil.copy2(compiled, executable)
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    else:
        subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    print(f"Host lifecycle fixture ready in {time.monotonic() - started:.2f} s", flush=True)
    if args.build_only:
        print(app, flush=True)
    else:
        if args.preview_native_design or (args.phase and "native-design" in args.phase):
            review = ROOT / "build/Perch Design Preview.app"
            shutil.copytree(app, review, dirs_exist_ok=True)
            for locale in (ROOT / "Resources/Localization").glob("*.lproj"):
                shutil.copytree(locale, review / "Contents/Resources" / locale.name, dirs_exist_ok=True)
            info = review / "Contents/Info.plist"
            metadata = plistlib.loads(info.read_bytes())
            metadata["CFBundleIdentifier"] = "dev.agentworkbench.hostqa.native-design.preview"
            metadata["PerchDesignPreview"] = True
            metadata["CFBundleName"] = "Perch Design Preview"
            metadata["CFBundleDisplayName"] = "Perch Design Preview"
            metadata["LSUIElement"] = False
            info.write_bytes(plistlib.dumps(metadata))
            subprocess.run(["codesign", "--force", "--sign", "-", str(review)], check=True)
            print(f"Persistent native design preview: {review}", flush=True)
        if args.preview_reading_design:
            review = ROOT / "build/Perch Reading Review.app"
            shutil.copytree(app, review, dirs_exist_ok=True)
            for locale in (ROOT / "Resources/Localization").glob("*.lproj"):
                shutil.copytree(locale, review / "Contents/Resources" / locale.name, dirs_exist_ok=True)
            info = review / "Contents/Info.plist"
            metadata = plistlib.loads(info.read_bytes())
            metadata.update(CFBundleIdentifier="dev.agentworkbench.hostqa.reading-review", PerchReadingPreview=True,
                            CFBundleName="Perch Reading Review", LSUIElement=False)
            info.write_bytes(plistlib.dumps(metadata))
            subprocess.run(["codesign", "--force", "--sign", "-", str(review)], check=True)
        try:
            for phase in args.phase or PHASES:
                started = time.monotonic()
                print(f"Running host lifecycle phase: {phase}", flush=True)
                preview = (args.preview_file_reader and phase == "file-reader") or (args.preview_document_reader and phase == "document-reading")
                if preview:
                    print(f"Native preview app: {app}", flush=True)
                command = [str(executable), phase, *(["preview"] if preview else [])]
                limit = 150 if preview else 60
                faulthandler.dump_traceback_later(limit + 15)
                process = subprocess.Popen(command)
                try:
                    process.wait(timeout=limit)
                except subprocess.TimeoutExpired:
                    print(f"Timed out host lifecycle phase: {phase}; sampling PID {process.pid}", flush=True)
                    try:
                        subprocess.run(["sample", str(process.pid), "1", "1"], timeout=5)
                    finally:
                        process.kill()
                        process.wait(timeout=5)
                    raise
                finally:
                    faulthandler.cancel_dump_traceback_later()
                if process.returncode:
                    raise subprocess.CalledProcessError(process.returncode, command)
                print(f"Passed host lifecycle phase: {phase} ({time.monotonic() - started:.2f} s)", flush=True)
        finally:
            print("Cleaning up host lifecycle preferences", flush=True)
            subprocess.run(["defaults", "delete", DOMAIN], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=10)
            shutil.rmtree(pathlib.Path.home() / "Library/Application Support" / DOMAIN, ignore_errors=True)
            print("Host lifecycle cleanup complete", flush=True)
