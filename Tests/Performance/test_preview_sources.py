"""Exercise real source export with a synthetic history, without a Swift toolchain."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
THEME = Path("Sources/AgentWorkbench/WorkbenchTheme.swift")
PRESENTATION = Path("Sources/AgentWorkbench/ConversationPresentationEnvironment.swift")


class PreviewSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        (self.repo / "scripts").mkdir()
        shutil.copy2(ROOT / "scripts/build-performance-preview.sh", self.repo / "scripts")
        self.git("init", "-q")
        self.git("config", "user.name", "Preview Test")
        self.git("config", "user.email", "fixture@example.test")
        app = self.repo / "Sources/AgentWorkbench"
        app.mkdir(parents=True)
        for name in (
            "UILocalization", "ConversationTranscriptView", "ConversationReadingMemory",
            "ConversationScrollControls", "ReplyMarkdownView", "KimiAttachmentView",
            "ConversationActivityBar", "WorkbenchGlass", "WorkspaceSplitView",
            "ToolActivityView", "NativeAssistantBlocks",
        ):
            (app / f"{name}.swift").write_text("// historical source\n")
        (self.repo / "Sources/WorkbenchCore").mkdir()
        (self.repo / "Sources/WorkbenchCore/Core.swift").write_text("// historical core\n")
        self.git("add", "Sources")
        self.git("commit", "-qm", "Before theme")
        self.before = self.git("rev-parse", "HEAD")
        (self.repo / THEME).write_text("// committed theme\n")
        for name in ("ActivitySummarySettings", "ActivitySummaryController"):
            (app / f"{name}.swift").write_text("// current summary source\n")
        self.git("add", "Sources")
        self.git("commit", "-qm", "Add theme")
        self.after = self.git("rev-parse", "HEAD")
        (self.repo / THEME).write_text("// working tree theme\n")
        (self.repo / PRESENTATION).write_text("// presentation environment\n")
        stubs = self.repo / "stubs"
        stubs.mkdir()
        # Stop immediately after source export, before metadata or compilation.
        for name, body in {"swift": "printf '/unused/toolchain\\n'", "python3": "exit 97"}.items():
            executable = stubs / name
            executable.write_text(f"#!/bin/sh\n{body}\n")
            executable.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}"}

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def check_export(self, variant, ref=None, baseline=None, theme=None, presentation=None):
        command = ["bash", "scripts/build-performance-preview.sh", variant]
        if ref:
            command.append(ref)
        env = {**self.env, "WORKBENCH_BASELINE_REF": baseline or self.before}
        result = subprocess.run(command, cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 97, result.stdout + result.stderr)
        snapshot = self.repo / ".local/performance-sources" / variant
        self.assertEqual((snapshot / PRESENTATION).exists(), presentation is not None)
        if presentation is not None:
            self.assertEqual((snapshot / PRESENTATION).read_text(), presentation)
        self.assertEqual((snapshot / THEME).exists(), theme is not None)
        if theme is not None:
            self.assertEqual((snapshot / THEME).read_text(), theme)
        self.assertEqual((snapshot / "Sources/WorkbenchCore/Core.swift").read_text(), "// historical core\n")

    def test_historical_baseline(self):
        self.check_export("baseline")

    def test_baseline_with_theme(self):
        self.check_export("baseline", baseline=self.after, theme="// committed theme\n")

    def test_historical_current_ref(self):
        self.check_export("current", ref=self.before)

    def test_current_ref_with_theme(self):
        self.check_export("current", ref=self.after, theme="// committed theme\n")

    def test_current_working_tree(self):
        self.check_export("current", theme="// working tree theme\n", presentation="// presentation environment\n")

    def test_current_ref_with_presentation(self):
        self.git("add", str(PRESENTATION))
        self.git("commit", "-qm", "Add presentation environment")
        self.check_export("current", ref=self.git("rev-parse", "HEAD"),
                          theme="// committed theme\n", presentation="// presentation environment\n")
