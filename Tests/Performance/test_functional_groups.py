import ast
import importlib.util
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

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
                         ["app-launch", "signature", "version", "workbench", "connections", "naming-lifecycle", "composer", "math-performance"])
        self.assertEqual([name for name, _, _ in functional.macos_commands("host", out)],
                         ["host-lifecycle", "scroll-following"])
        self.assertEqual([name for name, _, _ in functional.macos_commands("native", out)][:2],
                         ["native-build", "native-all"])
        navigation = [name for name, _, _ in functional.macos_commands("navigation", out)]
        self.assertEqual(navigation[0], "navigation-build")
        self.assertIn("navigation-turns", navigation)
        self.assertEqual(navigation[-1], "navigation-disclosure-full")

    def test_ci_core_shards_preserve_every_check(self):
        out = Path("/tmp/functional-groups")
        complete = [name for name, _, _ in functional.macos_commands("core", out)]
        sharded = [name for group in ("core-regression", "core-math")
                   for name, _, _ in functional.macos_commands(group, out)]
        self.assertEqual(sorted(sharded), sorted(complete + ["scroll-following"]))
        self.assertEqual(len(sharded), len(set(sharded)))

    def test_ci_host_shards_preserve_every_phase_once(self):
        out = Path("/tmp/functional-groups")
        sharded = []
        for group in functional.HOST_PHASE_GROUPS:
            commands = functional.macos_commands(group, out)
            self.assertEqual([name for name, _, _ in commands], ["host-lifecycle"])
            command = commands[0][1]
            sharded += [phase for flag, phase in zip(command, command[1:]) if flag == "--phase"]
        self.assertEqual(sorted(sharded), sorted(functional.HOST_PHASES))
        self.assertEqual(len(sharded), len(set(sharded)))
        self.assertEqual([name for name, _, _ in functional.macos_commands("host-build", out)], ["host-build"])

        module = ast.parse((ROOT / "scripts/check-host-lifecycle.py").read_text())
        phases = next(ast.literal_eval(node.value) for node in module.body
                      if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == "PHASES" for target in node.targets))
        self.assertEqual(functional.HOST_PHASES, phases)

    def test_ci_native_shards_preserve_every_mode_once(self):
        out = Path("/tmp/functional-groups")
        complete = [name for name, _, _ in functional.macos_commands("native", out) if name != "native-build"]
        sharded = [name for group in functional.NATIVE_MODE_GROUPS
                   for name, _, _ in functional.macos_commands(group, out)]
        self.assertEqual(sorted(sharded), sorted(complete))
        self.assertEqual(len(sharded), len(set(sharded)))
        self.assertEqual([name for name, _, _ in functional.macos_commands("native-build", out)], ["native-build"])

    def test_prebuilt_host_fixture_does_not_invoke_swift(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "HostLifecycleChecks.app"
            executable = app / "Contents/MacOS/HostLifecycleChecks"
            executable.parent.mkdir(parents=True)
            executable.write_text("fixture")
            domain = "dev.agentworkbench.hostqa." + uuid.uuid4().hex
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": domain}))
            process = type("Process", (), {"returncode": 0, "wait": lambda self, timeout=None: 0})()
            argv = ["check-host-lifecycle.py", "--app", str(app), "--phase", "startup"]
            with patch.object(sys, "argv", argv), \
                 patch.object(subprocess, "Popen", return_value=process) as popen, \
                 patch.object(subprocess, "run") as run, \
                 patch.object(subprocess, "check_output", side_effect=AssertionError("unexpected build")):
                runpy.run_path(str(ROOT / "scripts/check-host-lifecycle.py"), run_name="__main__")
            popen.assert_called_once_with([str(executable), "startup"])
            self.assertEqual(run.call_args_list[0].args[0][:3], ["codesign", "--verify", "--strict"])
            self.assertEqual(run.call_args_list[-1].args[0][:2], ["defaults", "delete"])

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
