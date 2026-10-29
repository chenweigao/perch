import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_functional", ROOT / "scripts/check-functional.py")
functional = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(functional)


class FunctionalGroupTests(unittest.TestCase):
    def test_all_is_exactly_the_union_of_the_parallel_groups(self):
        out = Path("/tmp/functional-groups")
        grouped = [name for group in ("build", "core", "host", "native", "navigation")
                   for name, _, _ in functional.macos_commands(group, out)]
        complete = [name for name, _, _ in functional.macos_commands("all", out)]
        self.assertEqual(complete, grouped)
        self.assertEqual(len(complete), len(set(complete)))
        self.assertEqual(complete.count("build"), 1)

    def test_each_group_has_the_expected_boundaries(self):
        out = Path("/tmp/functional-groups")
        self.assertEqual([name for name, _, _ in functional.macos_commands("build", out)], ["build"])
        self.assertEqual([name for name, _, _ in functional.macos_commands("core", out)],
                         ["app-launch", "signature", "version", "workbench", "connections", "composer"])
        self.assertEqual([name for name, _, _ in functional.macos_commands("host", out)],
                         ["host-lifecycle", "scroll-following"])
        self.assertEqual([name for name, _, _ in functional.macos_commands("native", out)][:2],
                         ["native-build", "native-all"])
        navigation = [name for name, _, _ in functional.macos_commands("navigation", out)]
        self.assertEqual(navigation[0], "navigation-build")
        self.assertIn("navigation-turns", navigation)
        self.assertEqual(navigation[-1], "navigation-disclosure-full")

    def test_portable_rejects_macos_groups(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(sys, "argv", ["check-functional.py", "portable", "--group", "build",
                                       "--output", str(Path(directory) / "out")]), \
             self.assertRaises(SystemExit) as exited:
            functional.main()
        self.assertEqual(exited.exception.code, 2)

    def test_group_report_keeps_identity_and_elapsed_time(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "out"
            process = type("Process", (), {"pid": 42, "wait": lambda self, timeout=None: 0})()
            argv = ["check-functional.py", "macos", "--group", "build", "--output", str(out)]
            with patch.object(sys, "argv", argv), patch.object(sys, "platform", "darwin"), \
                 patch.object(functional.subprocess, "Popen", return_value=process), \
                 patch.object(functional.subprocess, "check_output", return_value="fixture-commit\n"):
                self.assertEqual(functional.main(), 0)
            report = json.loads((out / "results.json").read_text())
            self.assertEqual(report["suite"], "macos")
            self.assertEqual(report["group"], "build")
            self.assertEqual(report["status"], "passed")
            self.assertEqual([entry["name"] for entry in report["checks"]], ["build"])
            self.assertGreaterEqual(report["seconds"], 0)


if __name__ == "__main__":
    unittest.main()
