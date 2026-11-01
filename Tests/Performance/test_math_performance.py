import copy
import importlib.util
import json
from pathlib import Path
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
            }} for _ in range(3)]
    return runs


class MathPerformanceTests(unittest.TestCase):
    def test_valid_results(self):
        result = MODULE.compare(fixtures())
        self.assertLess(result["comparison"]["parse_unclosed_4096"]["ratio"], 0.01)
        self.assertEqual(result["comparison"]["typeset-128"]["ratio"], 0.5)

    def test_later_changes_do_not_require_repeated_parser_gains(self):
        runs = fixtures()
        runs["baseline"]["parse-30"] = copy.deepcopy(runs["candidate"]["parse-30"])
        self.assertTrue(MODULE.compare(runs)["checks"])

    def test_semantic_mismatch_fails(self):
        runs = fixtures()
        runs["candidate"]["parse-30"][0]["measurements"]["reply"]["semantic_sha256"] = "changed"
        with self.assertRaisesRegex(ValueError, "semantic mismatch"):
            MODULE.compare(runs)

    def test_no_parser_improvement_fails(self):
        runs = fixtures()
        runs["candidate"]["parse-30"] = copy.deepcopy(runs["baseline"]["parse-30"])
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
