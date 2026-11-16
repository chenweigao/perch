import json
from pathlib import Path
import re
import statistics

ART = Path(__file__).resolve().parent
SOURCE = Path('<worktree>/.local/round32')
report = {'summaries': {}, 'raw_checks': {}, 'receipts': {}, 'raw_mismatches': []}
for name in ['macos-ab-v2-summary.json', 'linux-ab-v2-summary.json',
             'linux-ab-v2-edit-extra-summary.json', 'macos-ab-v1-summary.json', 'linux-ab-v1-summary.json']:
    summary = json.loads((SOURCE / name).read_text())
    failures = []
    positives = []
    for metric, row in summary.items():
        if 'baseline_samples' not in row:
            continue
        a, b = row['baseline_samples'], row['candidate_samples']
        am, bm = statistics.median(a), statistics.median(b)
        spread = max((max(a) - min(a)) / min(a) * 100 if min(a) else 0,
                     (max(b) - min(b)) / min(b) * 100 if min(b) else 0)
        change = (bm / am - 1) * 100 if am else 0
        worst = max(((bi - ai) / ai * 100 for ai, bi in zip(a, b) if ai > 0), default=0)
        expected = {'baseline_median': am, 'candidate_median': bm,
                    'max_spread_percent': spread, 'change_percent': change,
                    'worst_pair_percent': worst}
        for field, value in expected.items():
            if abs(row[field] - value) > 1e-8:
                failures.append([metric, field, row[field], value])
        if round(row['change_percent'], 2) > round(row['max_spread_percent'], 2) and round(row['worst_pair_percent'], 2) > 0:
            positives.append(metric)
    focused = {k: v for k, v in summary.items() if k.startswith('find_bar_') or k == 'edit64_unicode' or k == 'edit64_unchanged'}
    report['summaries'][name] = {'metrics': len(summary), 'arithmetic_mismatches': failures,
                                 'positives_beyond_spread': positives, 'focused': focused}

for dirname, summaryfile in [('macos-ab-v2', 'macos-ab-v2-summary.json'),
                             ('ab32v2', 'linux-ab-v2-summary.json')]:
    summary = json.loads((SOURCE / summaryfile).read_text())
    for pair in range(1, 7):
        for variant in ['baseline', 'candidate']:
            text = (SOURCE / dirname / f'pair{pair}-{variant}-streaming.log').read_text()
            for metric in ['find_bar_cold_query', 'find_bar_query_update', 'find_bar_reopen_query']:
                actual = float(re.search(r'^\s*' + metric + r'\s+median_ms=\s*([\d.]+)', text, re.M).group(1))
                expected = summary[metric][f'{variant}_samples'][pair - 1]
                if actual != expected:
                    report['raw_mismatches'].append([dirname, pair, variant, metric, actual, expected])

for dirname, summaryfile in [('macos-ab-v2', 'macos-ab-v2-summary.json'),
                             ('ab32v2', 'linux-ab-v2-summary.json'),
                             ('ab32v2-edit-extra', 'linux-ab-v2-edit-extra-summary.json')]:
    summary = json.loads((SOURCE / summaryfile).read_text())
    for pair in range(1, 7):
        for variant in ['baseline', 'candidate']:
            data = json.loads((SOURCE / dirname / f'pair{pair}-{variant}-edit-lines.log').read_text())
            for row in data['results']:
                metric = f"edit{row['source_rows']}_{row['case']}"
                if metric not in summary:
                    continue
                actual = row['median_ms']
                expected = summary[metric][f'{variant}_samples'][pair - 1]
                if abs(actual - expected) > 1e-12:
                    report['raw_mismatches'].append([dirname, pair, variant, metric, actual, expected])

for variant in ['base', 'cand']:
    text = (SOURCE / 'macos-ab-v2' / f'checks-{variant}.log').read_text()
    report['raw_checks'][variant] = {'pass': sum(s.startswith('PASS:') for s in text.splitlines()),
                                   'skip': sum(s.startswith('SKIP:') for s in text.splitlines())}
report['receipts']['mac_hashes_first_equal_last'] = (SOURCE / 'macos-ab-v2/binary-hashes.txt').read_text() == (SOURCE / 'macos-ab-v2/binary-hashes-final.txt').read_text()
report['receipts']['linux_v1_rebuild'] = (SOURCE / 'ab32v1/rebuild-receipt.txt').read_text()
report['receipts']['linux_v2_rebuild'] = (SOURCE / 'ab32v2/rebuild-receipt.txt').read_text()
report['raw_comparisons'] = {'streaming_values': 72, 'edit_values': 3 * 12 * 20}
full_raw_values = 0
for dirname, summaryfile in [('macos-ab-v2', 'macos-ab-v2-summary.json'),
                             ('ab32v2', 'linux-ab-v2-summary.json'),
                             ('macos-ab-v1', 'macos-ab-v1-summary.json'),
                             ('ab32v1', 'linux-ab-v1-summary.json')]:
    summary = json.loads((SOURCE / summaryfile).read_text())
    for pair in range(1, 7):
        for variant in ['baseline', 'candidate']:
            parsed = {}
            for mode in ['1', 'streaming', 'activity', 'edit-lines', 'presentation-token']:
                text = (SOURCE / dirname / f'pair{pair}-{variant}-{mode}.log').read_text()
                if mode == '1':
                    for size, cold, append in re.findall(r'source_slots=(\d+).*?cold_median_ms=([\d.]+).*?append_median_ms=([\d.]+)', text):
                        parsed['cold@' + size] = float(cold)
                        parsed['append@' + size] = float(append)
                elif mode == 'streaming':
                    for space, metric, value in re.findall(r'^(\s*)([a-z_0-9]+)\s+median_ms=\s*([\d.]+)\s*$', text, re.M):
                        prefix = {2: '', 4: 'stage_', 6: 'page_'}.get(len(space))
                        if prefix is not None:
                            parsed[prefix + metric] = float(value)
                elif mode == 'activity':
                    for size, edit, running, init in re.findall(r'turns=\d+ messages=(\d+) edit_stats_median_ms=([\d.]+) running_ids_median_ms=([\d.]+) activity_init_median_ms=([\d.]+)', text):
                        for name, value in [('edit_stats', edit), ('running_ids', running), ('activity_init', init)]:
                            parsed[name + '@' + size] = float(value)
                    for size, value in re.findall(r'single_turn_calls=\d+ messages=(\d+) activity_init_median_ms=([\d.]+)', text):
                        parsed['single_turn_activity@' + size] = float(value)
                elif mode == 'edit-lines':
                    for row in json.loads(text)['results']:
                        if row['source_rows'] in (64, 512):
                            parsed[f"edit{row['source_rows']}_{row['case']}"] = row['median_ms']
                else:
                    for row in json.loads(text)['results']:
                        scenario = row.get('scenario', 'same-id-tail-token-replacement')
                        prefix = 'token' if scenario == 'same-id-tail-token-replacement' else ('longtail' if scenario == 'long-tail-stream' else scenario.replace('-', '_'))
                        values = {}
                        for sample in row['samples']:
                            for field, value in sample.items():
                                if field.endswith('_ms'):
                                    values.setdefault(field, []).append(value)
                        for field, values_for_field in values.items():
                            parsed[f"{prefix}{row['fixture_turns']}_{field}"] = statistics.median(values_for_field)
            for metric, row in summary.items():
                expected = row[f'{variant}_samples'][pair - 1]
                actual = parsed.get(metric)
                full_raw_values += 1
                if actual is None or abs(actual - expected) > 1e-12:
                    report['raw_mismatches'].append([dirname, pair, variant, metric, actual, expected])
report['raw_comparisons']['all_v1_v2_values'] = full_raw_values
(ART / 'evidence-audit.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
for name, row in report['summaries'].items():
    print(name, 'metrics=', row['metrics'], 'arithmetic_mismatches=', len(row['arithmetic_mismatches']), 'positives=', row['positives_beyond_spread'])
print('raw_mismatches=', len(report['raw_mismatches']), 'checks=', report['raw_checks'], 'mac_hashes_equal=', report['receipts']['mac_hashes_first_equal_last'])
