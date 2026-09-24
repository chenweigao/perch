"""Exercise the supervisor's exit status without Instruments or a GUI."""
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ["os-signpost", "hitches-updates", "hitches",
           "hitches-frame-lifetimes", "display-vsyncs-interval"]


class FrameAcceptanceTests(unittest.TestCase):
    def run_capture(self, status="usable_frame_events", *, control=False,
                    detected=False, missing_schema=False, behavior=True):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            app = folder / "Fixture.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Resources").mkdir()
            (app / "Contents/MacOS/NativeAcceptance").write_bytes(b"fixture")
            (app / "Contents/Resources/build.json").write_text("{}")
            out = folder / "results"

            def launch(*args, **kwargs):
                (out / "result.json").write_text(json.dumps({"status": "passed" if behavior else "failed"}))
                process = unittest.mock.Mock(pid=123)
                process.wait.return_value = 0
                return process

            def run(command, **kwargs):
                if "export" in command:
                    destination = Path(command[command.index("--output") + 1])
                    if "--toc" in command:
                        schemas = SCHEMAS[:-1] if missing_schema else SCHEMAS
                        destination.write_text("<trace-toc>" + "".join(
                            f'<table schema="{schema}"/>' for schema in schemas) + "</trace-toc>")
                    else:
                        destination.write_text("<trace/>")
                    return subprocess.CompletedProcess(command, 0)
                self.assertEqual(Path(command[1]).name, "summarize-native-frames.py")
                return subprocess.CompletedProcess(command, 0, json.dumps({
                    "status": status, "positive_control_detected": detected}))

            argv = ["run-native-acceptance.py", "--app", str(app), "--output", str(out), "--capture", "frames"]
            if control:
                argv.append("--positive-control")
            with patch.object(sys, "argv", argv), patch("subprocess.Popen", side_effect=launch), \
                 patch("subprocess.run", side_effect=run), patch("builtins.print"), \
                 self.assertRaises(SystemExit) as exited:
                runpy.run_path(str(ROOT / "scripts/run-native-acceptance.py"), run_name="__main__")
            return exited.exception.code, json.loads((out / "manifest.json").read_text())

    def test_unverified_frames_fail_even_when_export_and_behavior_pass(self):
        code, manifest = self.run_capture("unverified")
        self.assertEqual(code, 1)
        self.assertTrue(manifest["behavior_passed"])
        self.assertTrue(manifest["trace_exported"])
        self.assertIn("unverified", manifest["failure"])

    def test_missing_schema_fails(self):
        self.assertEqual(self.run_capture(missing_schema=True)[0], 1)

    def test_missed_positive_control_fails(self):
        code, manifest = self.run_capture(control=True)
        self.assertEqual(code, 1)
        self.assertIn("known main-thread stall", manifest["failure"])

    def test_detected_positive_control_passes(self):
        self.assertEqual(self.run_capture(control=True, detected=True)[0], 0)

    def test_usable_baseline_passes(self):
        self.assertEqual(self.run_capture()[0], 0)

    def test_frame_data_does_not_hide_behavior_failure(self):
        self.assertEqual(self.run_capture(behavior=False)[0], 1)
