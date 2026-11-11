import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("math_performance", ROOT / "scripts/run-math-performance.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def fixtures():
    runs = {"baseline": {}, "candidate": {}}
    for variant in runs:
        factor = 1 if variant == "baseline" else 0.5
        cases = {}
        for name, old, new in [("reply", 3, 1), ("plain", 1, 1), ("ordinary_backslashes", 2, 1),
                               ("unclosed_256", 2, 0.1), ("unclosed_1024", 20, 0.4),
                               ("unclosed_4096", 300, 1.6)]:
            cases[name] = {"duration": {"median_ms": old if variant == "baseline" else new},
                           "semantic_sha256": name}
        runs[variant]["parse-30"] = [{"measurements": cases, "suffix_search": variant == "baseline"} for _ in range(3)]
        for count in [32, 128, 512]:
            runs[variant][f"typeset-{count}"] = [{"measurements": {
                "cold_attachment": {"total_ms": count * factor},
                "first_light_dark_draw": {"total_ms": count * factor},
                "warm_attachment": {"median_ms": 0.01},
                "rss_before_bytes": 1_000_000, "rss_after_bytes": 2_000_000,
            }} for _ in range(3)]
        for count in [30, 128]:
            runs[variant][f"window-{count}"] = [{"measurements": {
                "initial_layout_display_ms": 10 * factor,
                "scroll_work": {"p95_ms": factor},
                "scheduled_tick_gap": {"p95_ms": 16 + factor},
                "rss_before_bytes": 1_000_000, "rss_after_bytes": 1_000_000 + int(1_000_000 * factor),
            }} for _ in range(3)]
        for records in runs[variant].values():
            for record in records:
                record["source_input_sha256"] = ("a" if variant == "baseline" else "b") * 64
    return runs


class MathPerformanceTests(unittest.TestCase):
    def test_build_exports_locked_dependencies_and_nonempty_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            build = ROOT / "scripts/build-math-performance-preview.sh"
            shutil.copy2(build, scripts)
            fixture = root / "Tests/MathPerformancePreview"
            fixture.mkdir(parents=True)
            shutil.copy2(ROOT / "Tests/MathPerformancePreview/App.swift", fixture)
            core = root / "Sources/WorkbenchCore"
            core.mkdir(parents=True)
            (core / "ReplyMath.swift").write_text("import Foundation\n")
            app = root / "Sources/AgentWorkbench"
            app.mkdir()
            names = re.search(r"for name in (.*?); do", build.read_text()).group(1).split()
            for name in names:
                (app / (name + ".swift")).write_text("import Foundation\n")
            shutil.copy2(ROOT / "Package.resolved", root)
            for command in [["init", "-q"], ["config", "user.name", "Math Test"],
                            ["config", "user.email", "fixture@example.test"], ["add", "."],
                            ["commit", "-qm", "Math fixture"]]:
                subprocess.run(["git", *command], cwd=root, check=True, capture_output=True)
            stubs = root / "stubs"
            stubs.mkdir()
            binary = root / "bin"
            for target in ["WorkbenchCore", "Markdown", "CAtomic", "cmark_gfm", "cmark_gfm_extensions", "SwiftMath"]:
                folder = binary / (target + ".build")
                folder.mkdir(parents=True)
                (folder / "fixture.o").write_bytes(b"")
            for name, content in {
                "swift": '#!/bin/sh\ncase "$*" in\n*--show-bin-path*) printf "%s\\n" "$MATH_TEST_BIN";;\n*--version*) printf "fixture toolchain\\n";;\nesac\n',
                "swiftc": '#!/bin/sh\nprintf "%s\\n" "$@" > "$MATH_TEST_ARGUMENTS"\nexit 97\n',
            }.items():
                path = stubs / name
                path.write_text(content)
                path.chmod(0o755)
            arguments = root / "arguments.txt"
            environment = {**os.environ, "PATH": str(stubs) + os.pathsep + os.environ["PATH"],
                           "MATH_TEST_BIN": str(binary), "MATH_TEST_ARGUMENTS": str(arguments)}
            pins = {pin["identity"]: pin for pin in json.loads((root / "Package.resolved").read_text())["pins"]}
            fingerprints = []
            for variant in ["baseline", "candidate"]:
                if variant == "candidate":
                    (root / "README.md").write_text("Unrelated change\n")
                    subprocess.run(["git", "add", "README.md"], cwd=root, check=True, capture_output=True)
                    subprocess.run(["git", "commit", "-qm", "Unrelated change"], cwd=root, check=True, capture_output=True)
                result = subprocess.run(["bash", "scripts/build-math-performance-preview.sh", variant],
                                        cwd=root, env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 97, result.stdout + result.stderr)
                flags = arguments.read_text().splitlines()
                self.assertIn("-D", flags)
                self.assertIn("MATH_PERFORMANCE_BASELINE" if variant == "baseline" else "MATH_PERFORMANCE_CHECKS", flags)
                snapshot = root / ".local/math-performance-sources" / variant
                metadata = json.loads((root / f"build/Math Performance {variant}.app/Contents/Resources/build.json").read_text())
                fingerprints.append(metadata["source_input_sha256"])
                package = (snapshot / "Package.swift").read_text()
                for name in ["swift-markdown", "swift-cmark", "swiftmath"]:
                    pin = pins[name]
                    self.assertIn('.package(url: ' + json.dumps(pin["location"]) + ', exact: ' + json.dumps(pin["state"]["version"]) + ')', package)
            self.assertEqual(fingerprints[0], fingerprints[1])
            # A source edit outside ReplyMathView must still invalidate identity.
            (core / "NewInput.swift").write_text("struct NewInput {}\n")
            subprocess.run(["git", "add", "Sources"], cwd=root, check=True, capture_output=True)
            subprocess.run(["git", "commit", "-qm", "Change compiled inputs"], cwd=root, check=True, capture_output=True)
            shutil.rmtree(root / ".local/math-performance-sources/candidate")
            shutil.rmtree(root / "build/Math Performance candidate.app")
            result = subprocess.run(["bash", "scripts/build-math-performance-preview.sh", "candidate"],
                                    cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 97, result.stdout + result.stderr)
            metadata = json.loads((root / "build/Math Performance candidate.app/Contents/Resources/build.json").read_text())
            self.assertNotEqual(metadata["source_input_sha256"], fingerprints[0])

    def test_identical_inputs_report_measurements_without_claiming_a_regression(self):
        runs = fixtures()
        runs["baseline"] = copy.deepcopy(runs["candidate"])
        for record in runs["candidate"]["typeset-128"]:
            record["measurements"]["cold_attachment"]["total_ms"] *= 2
        result = MODULE.compare(runs)
        self.assertGreater(result["comparison"]["typeset-128"]["ratio"], 1.1)
        self.assertEqual(result["input_comparison"]["relative_performance_gates"],
                         "not_applicable_identical_inputs")
        # The same timings with an actual input change must fail the old gate.
        for records in runs["candidate"].values():
            for record in records:
                record["source_input_sha256"] = "c" * 64
        # Keep this negative control focused on typesetting.
        for record in runs["baseline"]["parse-30"]:
            record["suffix_search"] = False
        with self.assertRaisesRegex(ValueError, "regression exceeds"):
            MODULE.compare(runs)

    def test_identical_inputs_still_check_semantics_and_growth(self):
        for failure in ["semantic mismatch", "grew too quickly"]:
            runs = fixtures()
            runs["baseline"] = copy.deepcopy(runs["candidate"])
            for record in runs["candidate"]["parse-30"]:
                if failure == "semantic mismatch":
                    record["measurements"]["reply"]["semantic_sha256"] = "changed"
                else:
                    record["measurements"]["unclosed_4096"]["duration"]["median_ms"] = 10
            with self.assertRaisesRegex(ValueError, failure):
                MODULE.compare(runs)

    def test_missing_or_mixed_identity_cannot_disable_gates(self):
        for fingerprint in [None, "", "invalid", "c" * 64]:
            runs = fixtures()
            runs["candidate"]["typeset-32"][0]["source_input_sha256"] = fingerprint
            with self.assertRaisesRegex(ValueError, "input identity"):
                MODULE.compare(runs)

    def test_valid_results(self):
        result = MODULE.compare(fixtures())
        self.assertLess(result["comparison"]["parse_unclosed_4096"]["ratio"], 0.01)
        self.assertEqual(result["comparison"]["typeset-128"]["ratio"], 0.5)

    def test_later_changes_do_not_require_repeated_parser_gains(self):
        runs = fixtures()
        runs["baseline"]["parse-30"] = copy.deepcopy(runs["candidate"]["parse-30"])
        for record in runs["baseline"]["parse-30"]:
            record["source_input_sha256"] = "a" * 64
        self.assertTrue(MODULE.compare(runs)["checks"])

    def test_semantic_mismatch_fails(self):
        runs = fixtures()
        runs["candidate"]["parse-30"][0]["measurements"]["reply"]["semantic_sha256"] = "changed"
        with self.assertRaisesRegex(ValueError, "semantic mismatch"):
            MODULE.compare(runs)

    def test_no_parser_improvement_fails(self):
        runs = fixtures()
        runs["candidate"]["parse-30"] = copy.deepcopy(runs["baseline"]["parse-30"])
        for record in runs["candidate"]["parse-30"]:
            record["source_input_sha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "did not improve"):
            MODULE.compare(runs)

    def test_superlinear_growth_fails(self):
        runs = fixtures()
        for record in runs["candidate"]["parse-30"]:
            record["measurements"]["unclosed_4096"]["duration"]["median_ms"] = 10
        with self.assertRaisesRegex(ValueError, "grew too quickly"):
            MODULE.compare(runs)

    def test_raster_regression_fails(self):
        runs = fixtures()
        for record in runs["candidate"]["typeset-128"]:
            record["measurements"]["cold_attachment"]["total_ms"] = 500
        with self.assertRaisesRegex(ValueError, "regression exceeds"):
            MODULE.compare(runs)

    def test_window_memory_regression_fails(self):
        runs = fixtures()
        for record in runs["candidate"]["window-128"]:
            record["measurements"]["rss_after_bytes"] = 3_000_000
        with self.assertRaisesRegex(ValueError, "Window retained memory regressed"):
            MODULE.compare(runs)

    def test_window_initial_layout_regression_fails(self):
        # Only a catastrophic best-case blowout (over 3x) is gated.
        runs = fixtures()
        for record in runs["candidate"]["window-30"]:
            record["measurements"]["initial_layout_display_ms"] = 31
        with self.assertRaisesRegex(ValueError, "Window initial layout regressed"):
            MODULE.compare(runs)

    def test_window_initial_layout_triple_boundary_passes(self):
        runs = fixtures()
        for record in runs["candidate"]["window-30"]:
            record["measurements"]["initial_layout_display_ms"] = 30
        MODULE.compare(runs)

    def test_window_initial_layout_load_spike_passes(self):
        # Two loaded rounds out of three move the median past the ratio gate;
        # the best-case comparison must not read a scheduling spike as a layout
        # regression.
        runs = fixtures()
        for record in runs["candidate"]["window-30"][:2]:
            record["measurements"]["initial_layout_display_ms"] = 15
        MODULE.compare(runs)

    def test_typeset_early_round_warmup_spike_passes(self):
        runs = fixtures()
        runs["baseline"]["parse-30"] = copy.deepcopy(runs["candidate"]["parse-30"])
        for record in runs["baseline"]["parse-30"]:
            record["source_input_sha256"] = "a" * 64
        for record in runs["baseline"]["typeset-32"]:
            record["measurements"]["cold_attachment"]["total_ms"] = 50
            record["measurements"]["first_light_dark_draw"]["total_ms"] = 50
        for record in runs["candidate"]["typeset-32"][:2]:
            record["measurements"]["cold_attachment"]["total_ms"] = 70
            record["measurements"]["first_light_dark_draw"]["total_ms"] = 70
        runs["candidate"]["typeset-32"][2]["measurements"]["cold_attachment"]["total_ms"] = 53
        runs["candidate"]["typeset-32"][2]["measurements"]["first_light_dark_draw"]["total_ms"] = 53
        MODULE.compare(runs)

    def test_nonfinite_samples_fail(self):
        for value in [-1, float("nan"), float("inf")]:
            with self.assertRaises(ValueError):
                MODULE.median([value])

    def test_failed_and_missing_results_do_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            with self.assertRaises(FileNotFoundError):
                MODULE.read_result(path, "parse")
            path.write_text(json.dumps({"status": "failed", "mode": "parse"}))
            with self.assertRaises(ValueError):
                MODULE.read_result(path, "parse")
            path.write_text(json.dumps({"status": "passed", "mode": "parse", "measurements": {}}))
            with self.assertRaises(ValueError):
                MODULE.read_result(path, "parse")
            path.write_text(json.dumps({"status": "passed", "mode": "parse", "revision": "fixture", "measurements": {}}))
            self.assertEqual(MODULE.read_result(path, "parse")["revision"], "fixture")
            with self.assertRaises(ValueError):
                MODULE.read_result(path, "window")


if __name__ == "__main__":
    unittest.main()
