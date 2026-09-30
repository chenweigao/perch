"""Time-profile intervals exclude startup and the following scroll scenario."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TimeProfileIntervalTests(unittest.TestCase):
    def test_context_partition_conserves_weight_and_prioritizes_nested_row_measure(self):
        stacks = [
            ['ReplyTextView.measure(width:)', 'ConversationEntryController.measure(width:)',
             'ConversationDocumentView.refreshVisibleRows()', 'AG::Graph::UpdateStack::update'],
            ['SessionRowChrome.body.getter', 'AG::Graph::UpdateStack::update'],
            ['AG::Graph::UpdateStack::update', '_layoutSubtreeWithOldSize'],
            ['unknown'],
        ]
        rows = []
        for names in stacks:
            frames = ''.join(f'<frame name="{name}"/>' for name in names)
            rows.append('<row><time>1000000000</time><thread fmt="Main Thread"/>'
                        '<process/><core/><state/><weight>2000000</weight>'
                        f'<stack>{frames}</stack></row>')
        # A background sample must not leak into the main-thread partition.
        rows.append(rows[0].replace('Main Thread', 'Worker'))
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'profile.xml'
            path.write_text('<root>' + ''.join(rows) + '</root>')
            result = subprocess.run(['python3', str(ROOT / 'scripts/summarize-time-profile.py'),
                                     str(path)], check=True, capture_output=True, text=True)
        summary = json.loads(result.stdout)
        self.assertEqual(summary['main_stack_context_partition_ms'], {
            'row_measure': 2, 'sidebar': 2, 'framework_graph_remaining': 2, 'other': 2})
        self.assertEqual(sum(summary['main_stack_context_partition_ms'].values()), summary['main_sampled_cpu_ms'])

    def test_half_open_interval_counts_only_selected_samples(self):
        rows = []
        for second in range(4):
            rows.append(f'<row><time>{second * 1000000000}</time><thread fmt="Main Thread"/>'
                        '<process/><core/><state/><weight>1000000</weight>'
                        '<stack><frame name="fixture"><binary name="NativeAcceptance"/></frame></stack></row>')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'profile.xml'
            path.write_text('<root>' + ''.join(rows) + '</root>')
            result = subprocess.run(['python3', str(ROOT / 'scripts/summarize-time-profile.py'),
                                     str(path), '--after', '1', '--before', '3'], check=True, capture_output=True, text=True)
        summary = json.loads(result.stdout)
        self.assertEqual(summary['sample_rows'], 2)
        self.assertEqual(summary['main_sampled_cpu_ms'], 2)
        self.assertEqual(summary['main_cpu_ms_per_second'], {'1': 1, '2': 1})

    def test_reversed_interval_is_rejected(self):
        result = subprocess.run(['python3', str(ROOT / 'scripts/summarize-time-profile.py'),
                                 'unused.xml', '--after', '3', '--before', '1'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--before must be later', result.stderr)
