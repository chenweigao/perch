import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('input_runs', ROOT / 'scripts/summarize-input-runs.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class InputRunsTests(unittest.TestCase):
    def fixtures(self, root):
        paths = []
        for index in range(3):
            path = root / str(index)
            path.mkdir()
            (path / 'manifest.json').write_text(json.dumps({'capture': 'none', 'input_positive_control': False,
                'exit_code': 0, 'behavior_passed': True, 'mode': 'input', 'source_sha256': 'source',
                'binary_sha256': 'binary', 'compiler': 'swift', 'window_points': [1280, 820]}))
            (path / 'result.json').write_text(json.dumps({'status': 'passed', 'mode': 'input',
                'input_positive_control': False, 'input_composition_cycles': 1, 'input_max_anchor_drift_points': 0,
                'input_metrics': {'commit_layout_ms': {'median': index + 1, 'p95': index + 4}},
                'input_samples': [{'plain_reader_evaluations': 0, 'commit_reader_evaluations': 0}]}))
            paths.append(path)
        return paths

    def test_reports_run_variation_without_pooling(self):
        with tempfile.TemporaryDirectory() as folder:
            result = module.summarize(self.fixtures(Path(folder)))
        metrics = result['providers']['input']['metrics']['commit_layout_ms']
        self.assertEqual(metrics['median_of_run_medians_ms'], 2)
        self.assertEqual(metrics['run_p95_range_ms'], [4, 6])

    def test_refuses_mixed_sources_controls_and_captures(self):
        for field, value in [('source_sha256', 'different'), ('capture', 'cpu'), ('input_positive_control', True)]:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as folder:
                paths = self.fixtures(Path(folder))
                path = paths[1] / 'manifest.json'
                manifest = json.loads(path.read_text()); manifest[field] = value
                path.write_text(json.dumps(manifest))
                with self.assertRaises(ValueError): module.summarize(paths)

    def test_duplicate_or_missing_repetitions_do_not_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            paths = self.fixtures(Path(folder))
            for selected in [paths[:2], [paths[0]] * 3]:
                with self.assertRaises(ValueError): module.summarize(selected)
