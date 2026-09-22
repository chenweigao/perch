#!/usr/bin/env python3
"""After scripts/build.sh, check native scroll-following behavior in isolation."""
import pathlib
import platform
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = pathlib.Path(subprocess.check_output(
    ["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, text=True).strip())
files = ["ToolActivityView", "ConversationTranscriptView", "ConversationReadingMemory",
         "ActivitySummarySettings", "ActivitySummaryController",
         "ConversationScrollControls", "ReplyMarkdownView", "KimiAttachmentView",
         "ConversationActivityBar", "WorkbenchGlass"]
includes = ["-I", str(BIN / "Modules")]
for path in ["swift-markdown/Sources/CAtomic/include", "swift-cmark/src/include", "swift-cmark/extensions/include"]:
    includes += ["-I", str(ROOT / ".build/checkouts" / path)]
objects = []
for target in ["WorkbenchCore", "Markdown", "CAtomic", "cmark_gfm", "cmark_gfm_extensions"]:
    objects += sorted((BIN / (target + ".build")).glob("*.o"))
with tempfile.TemporaryDirectory(prefix="perch-scroll-check-") as folder:
    work = pathlib.Path(folder)
    app = work / "ScrollFollowingChecks.app"
    executable = app / "Contents/MacOS/ScrollFollowingChecks"
    executable.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "dev.agentworkbench.scrollfollowingqa",
        "CFBundleName": "Scroll Following Checks", "CFBundleExecutable": executable.name,
        "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    compiled = work / "compiled"
    subprocess.run([
        "swiftc", "-Onone", "-swift-version", "5", "-parse-as-library", "-target", platform.machine() + "-apple-macosx14.0", *includes,
        *[str(ROOT / "Sources/AgentWorkbench" / (name + ".swift")) for name in files],
        str(ROOT / "Tests/ScrollFollowingChecks/App.swift"), *map(str, objects), "-o", str(compiled),
    ], cwd=ROOT, check=True)
    shutil.copy2(compiled, executable)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
