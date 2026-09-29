import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('renderer_summary', Path(__file__).resolve().parents[2] / 'scripts/summarize-renderer-experiment.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RendererExperimentTests(unittest.TestCase):
    def fixtures(self, root):
        for variant in ('flat', 'table'):
            for n in range(1, 4):
                path = root / f'{variant}-render-catalog-r{n}'
                path.mkdir()
                manifest = dict(sidebar_variant=variant, capture='none', source_sha256='source', binary_sha256='binary',
                                compiler='compiler', window_points=[1280, 820], mode='render-catalog', exit_code=0)
                result = dict(status='passed', render_step_ms=dict(median=10, p95=12, max=15),
                              main_actor_lateness=dict(p99_ms=2, max_ms=3, over_50ms=0))
                (path / 'manifest.json').write_text(json.dumps(manifest))
                (path / 'result.json').write_text(json.dumps(result))

    def test_missing_live_evidence_and_controls_are_not_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixtures(root)
            result = module.summarize(root)
            self.assertFalse(result['main_actor_control_verified'])
            self.assertEqual(result['real_display_frames'], 'unverified')
            self.assertEqual(result['hardware_input_and_ime'], 'unverified')

    def test_mixed_binaries_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixtures(root)
            path = root / 'table-render-catalog-r1/manifest.json'
            value = json.loads(path.read_text()); value['binary_sha256'] = 'different'; path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'identity'): module.summarize(root)

    def test_incomplete_repeats_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.fixtures(root)
            (root / 'table-render-catalog-r3/result.json').unlink()
            with self.assertRaisesRegex(ValueError, 'expected three'): module.summarize(root)
