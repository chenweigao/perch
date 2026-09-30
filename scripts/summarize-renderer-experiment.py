#!/usr/bin/env python3
"""Compare fixed-build sidebar renderers; missing real display/input evidence stays unverified."""
import argparse
import json
from pathlib import Path
from statistics import median


def summarize(root):
    groups = {}
    identities = set()
    control_identities = set()
    runs = []
    controls = []
    for path in sorted(root.glob('*/manifest.json')):
        result_path = path.parent / 'result.json'
        if not result_path.exists():
            continue
        manifest = json.loads(path.read_text())
        result = json.loads(result_path.read_text())
        variant = manifest.get('sidebar_variant')
        if variant not in ('flat', 'table'):
            continue
        if manifest.get('responsiveness_control'):
            control_identities.add((manifest['source_sha256'], manifest['binary_sha256'], manifest['compiler'], tuple(manifest['window_points'])))
            controls.append({'variant': variant, 'passed': manifest.get('behavior_passed', False) and
                             result.get('responsiveness_control_detected', False), 'name': path.parent.name})
            continue
        if '-r' not in path.parent.name or manifest.get('capture') != 'none':
            continue
        if result.get('status') != 'passed' or manifest.get('exit_code') != 0:
            raise ValueError('Failed timed run: ' + path.parent.name)
        identities.add((manifest['source_sha256'], manifest['binary_sha256'], manifest['compiler'],
                        tuple(manifest['window_points'])))
        mode = manifest['mode']
        metrics = {}
        for key in ('render_step_ms', 'layout_step_ms', 'joint_input_to_layout_ms', 'joint_update_to_layout_ms'):
            if key in result:
                metrics[key] = result[key]
        if 'input_metrics' in result:
            metrics['input_commit_ms'] = result['input_metrics']['commit_layout_ms']
        record = {'name': path.parent.name, 'variant': variant, 'mode': mode, 'metrics': metrics,
                  'main_actor_lateness': result.get('main_actor_lateness'),
                  'cpu_seconds': next((result[k] for k in ('render_process_cpu_seconds', 'layout_process_cpu_seconds', 'joint_cpu_seconds') if k in result), None),
                  'anchor_drift_points': result.get('input_max_anchor_drift_points'),
                  'input_composition_preserved': result.get('input_marked_text_preserved'),
                  'rss_settled_mb': result.get('rss_settled_mb'), 'manifest': manifest}
        runs.append(record)
        groups.setdefault((mode, variant), []).append(record)
    if len(identities) != 1:
        raise ValueError('Expected exactly one source/binary/compiler/window identity')
    if control_identities - identities:
        raise ValueError("Positive control has a different build identity")
    comparisons = {}
    for mode in sorted({k[0] for k in groups}):
        by_variant = {}
        for variant in ('flat', 'table'):
            values = groups.get((mode, variant), [])
            if len(values) != 3:
                raise ValueError(f'{mode}/{variant}: expected three runs, got {len(values)}')
            metrics = {}
            for key in values[0]['metrics']:
                metrics[key] = {p: median(v['metrics'][key][p] for v in values) for p in ('median', 'p95', 'max')}
                metrics[key]['median_range'] = [min(v['metrics'][key]['median'] for v in values), max(v['metrics'][key]['median'] for v in values)]
            by_variant[variant] = {'metrics': metrics,
                'cpu_seconds': median(v['cpu_seconds'] for v in values) if values[0]['cpu_seconds'] is not None else None,
                'main_actor_p99_ms': median(v['main_actor_lateness']['p99_ms'] for v in values),
                'main_actor_max_ms': max(v['main_actor_lateness']['max_ms'] for v in values),
                'over_50ms_per_run': [v['main_actor_lateness']['over_50ms'] for v in values]}
        comparisons[mode] = by_variant
    return {'comparisons': comparisons, 'runs': runs, 'controls': controls,
            'main_actor_control_verified': all(any(c['variant'] == v and c['passed'] for c in controls) for v in ('flat', 'table')),
            'real_display_frames': 'unverified', 'hardware_input_and_ime': 'unverified',
            'production_adoption': 'requires complete interaction and real-experience acceptance',
            'boundary': 'Three-run medians, fixed offline fixture. Main-actor lateness is not FPS; missing evidence is not a pass.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runs', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(json.dumps(summarize(args.runs), indent=2, ensure_ascii=False) + '\n')
