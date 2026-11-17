import collections
import hashlib
import importlib.util
import json
import math
import pathlib
import re
import statistics
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True

ROOT = pathlib.Path(__file__).resolve().parent.parent
EVIDENCE = pathlib.Path('<worktree>/.local/round33')
OUT = ROOT / 'review-artifacts'
spec = importlib.util.spec_from_file_location('r33', EVIDENCE / 'analyze_r33.py')
r33 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r33)

def parse(mode, text):
    result = {}
    if mode == '1':
        for m in re.finditer(r'source_slots=(\d+).*?cold_median_ms=([\d.]+).*?append_median_ms=([\d.]+)', text):
            result['cold@' + m[1]] = float(m[2])
            result['append@' + m[1]] = float(m[3])
    elif mode == 'streaming':
        for line in text.splitlines():
            m = re.fullmatch(r'(\s*)([a-z_0-9]+)\s+median_ms=\s*([\d.]+)', line)
            if m and len(m[1]) in (2, 4, 6):
                result[{2: '', 4: 'stage_', 6: 'page_'}[len(m[1])] + m[2]] = float(m[3])
    elif mode == 'activity':
        for m in re.finditer(r'turns=(\d+) messages=(\d+) edit_stats_median_ms=([\d.]+) running_ids_median_ms=([\d.]+) activity_init_median_ms=([\d.]+)', text):
            for name, value in zip(('edit_stats', 'running_ids', 'activity_init'), m.groups()[2:]):
                result[name + '@' + m[2]] = float(value)
        for m in re.finditer(r'single_turn_calls=(\d+) messages=(\d+) activity_init_median_ms=([\d.]+)', text):
            result['single_turn_activity@' + m[2]] = float(m[3])
    else:
        data = json.loads(text)
        for item in data['results']:
            if mode == 'edit-lines' and item['source_rows'] in (64, 512):
                result[f"edit{item['source_rows']}_{item['case']}"] = item['median_ms']
            elif mode == 'presentation-token':
                scenario = item.get('scenario', 'same-id-tail-token-replacement')
                prefix = {'same-id-tail-token-replacement': 'token', 'long-tail-stream': 'longtail'}.get(scenario, scenario.replace('-', '_'))
                for key in item['samples'][0]:
                    if key.endswith('_ms'):
                        result[f"{prefix}{item['fixture_turns']}_{key}"] = statistics.median([s[key] for s in item['samples']])
    return result

report = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'ab': {}, 'attribution': {}}
for platform, folder in [('macos', 'macos-ab-v1'), ('linux', 'ab33v1')]:
    samples = collections.defaultdict(lambda: {'baseline': [], 'candidate': []})
    receipts = []
    for pair in range(1, 7):
        for side in ('baseline', 'candidate'):
            for mode in ('1', 'streaming', 'activity', 'edit-lines', 'presentation-token'):
                path = EVIDENCE / folder / f'pair{pair}-{side}-{mode}.log'
                text = path.read_text()
                receipts.append({'file': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
                for key, value in parse(mode, text).items():
                    samples[key][side].append(value)
    actual = {}
    for key, values in samples.items():
        b, c = values['baseline'], values['candidate']
        assert len(b) == len(c) == 6, (key, values)
        if not max(b) and not max(c):
            continue
        bm, cm = statistics.median(b), statistics.median(c)
        actual[key] = {'baseline_samples': b, 'candidate_samples': c, 'baseline_median': bm, 'candidate_median': cm,
                       'change_percent': (cm - bm) / bm * 100 if bm else float('nan'),
                       'worst_pair_percent': max([(ci - bi) / bi * 100 for bi, ci in zip(b, c) if bi] or [0.0]),
                       'max_spread_percent': max((max(x) - min(x)) / min(x) * 100 if min(x) else 0 for x in (b, c))}
    claimed = json.loads((EVIDENCE / f'{platform}-ab-v1-summary.json').read_text())
    assert claimed.keys() == actual.keys(), (claimed.keys() - actual.keys(), actual.keys() - claimed.keys())
    mismatches = []
    fields = 0
    for key, stats in actual.items():
        for field, value in stats.items():
            fields += len(value) if isinstance(value, list) else 1
            other = claimed[key][field]
            if value != other and not (isinstance(value, float) and math.isnan(value) and math.isnan(other)):
                mismatches.append([key, field, value, other])
    positives = [key for key, v in actual.items() if round(v['change_percent'], 2) > round(v['max_spread_percent'], 2) and round(v['worst_pair_percent'], 2) > 0]
    checks = {}
    for side in ('base', 'cand'):
        text = (EVIDENCE / folder / f'checks-{side}.log').read_text()
        checks[side] = {'pass': len(re.findall(r'^PASS', text, re.M)), 'skip': len(re.findall(r'^SKIP', text, re.M)), 'has_final_pass': 'PASS: protocol decoding, shell argument isolation, SSH destination validation' in text}
    headline = {key: actual[key] for key in ('find_bar_reopen_query', 'find_bar_query_update', 'find_bar_cold_query')}
    for key, stats in headline.items():
        b, c = stats['baseline_samples'], stats['candidate_samples']
        stats['six_pairs_negative'] = all(ci < bi for bi, ci in zip(b, c))
        stats['ranges_separated'] = max(c) < min(b)
    r = headline['find_bar_reopen_query']
    b, c = r['baseline_samples'], r['candidate_samples']
    base_step, cand_step = 0.005, 0.00005
    r['quantization_change_interval'] = [(statistics.median(c) - cand_step) / (statistics.median(b) + base_step) * 100 - 100,
                                          (statistics.median(c) + cand_step) / (statistics.median(b) - base_step) * 100 - 100]
    r['quantization_worst_conservative'] = max((ci + cand_step) / (bi - base_step) * 100 - 100 for bi, ci in zip(b, c))
    r['quantization_separated_conservative'] = max(c) + cand_step < min(b) - base_step
    r['quantization_max_spread_bound'] = max((max(b) + base_step - min(b) + base_step) / (min(b) - base_step) * 100,
                                             (max(c) + cand_step - min(c) + cand_step) / (min(c) - cand_step) * 100)
    report['ab'][platform] = {'metrics': len(actual), 'numeric_fields': fields, 'mismatches': mismatches, 'positives': positives, 'checks': checks, 'headline': headline, 'receipts': receipts}
    print(platform, 'metrics', len(actual), 'numeric_fields', fields, 'mismatches', len(mismatches), 'positives', positives, 'checks', checks)
    print(json.dumps(headline, ensure_ascii=False, indent=2))

for shape in ('cold', 'reopen'):
    xmlpath = EVIDENCE / 'xml' / f'{shape}-time-profile.xml'
    frames_cache, backtrace_cache, samples = {}, {}, []
    time_cache = {}
    for _, row in ET.iterparse(xmlpath, events=('end',)):
        if row.tag != 'row':
            continue
        stamp = row.find('sample-time')
        if stamp is not None:
            if stamp.get('ref'):
                time = time_cache[stamp.get('ref')]
            else:
                time = int(stamp.text) / 1e9
                if stamp.get('id'):
                    time_cache[stamp.get('id')] = time
        bt = row.find('tagged-backtrace')
        if bt is None:
            row.clear()
            continue
        if bt.get('ref'):
            frames = backtrace_cache[bt.get('ref')]
        else:
            frames = []
            for fr in bt.findall('frame'):
                if fr.get('ref'):
                    name = frames_cache[fr.get('ref')]
                else:
                    name = fr.get('name') or ('0x' + (fr.get('addr') or '?'))
                    if fr.get('id'):
                        frames_cache[fr.get('id')] = name
                frames.append(name)
            if bt.get('id'):
                backtrace_cache[bt.get('id')] = frames
        if frames:
            samples.append((time, frames, r33.classify(frames)))
        row.clear()
    totals = collections.Counter(label for _, _, label in samples)
    expected = (EVIDENCE / f'{shape}-attribution.txt').read_text()
    expected_total = int(re.search(r'total_samples=(\d+)', expected)[1])
    assert len(samples) == expected_total, (shape, len(samples), expected_total)
    expected_regions = {m[2]: int(m[1]) for m in re.finditer(r'^\s*(\d+)\s+[\d.]+%\s+[\d.]+%\s+([\w-]+)\s*$', expected, re.M)}
    assert dict(totals) == expected_regions
    windows = {}
    for threshold in (0, 1.5, 1.74, 2, 3, 5, 10):
        selected = [(t, f, r) for t, f, r in samples if t > threshold]
        count = len(selected)
        regions = collections.Counter(r for _, _, r in selected)
        cf_leaves = collections.Counter(f[0] for _, f, r in selected if r == 'cf-match')
        node_leaves = collections.Counter(f[0] for _, f, r in selected if r == 'prefix-verify')
        windows[str(threshold)] = {'samples': count, 'regions': dict(regions), 'percent': {r: n / count * 100 for r, n in regions.items()}, 'cf_leaves': dict(cf_leaves), 'prefix_verify_leaves': dict(node_leaves)}
    rule_a = collections.Counter(tuple(f[:7]) for _, f, r in samples if f[0] in r33.ARC_LEAVES)
    rule_b = collections.Counter(tuple(f[:8]) for _, f, r in samples if any('ConversationPrefixCache.node(' in s for s in f))
    report['attribution'][shape] = {'xml': str(xmlpath), 'sha256': hashlib.sha256(xmlpath.read_bytes()).hexdigest(), 'total': len(samples), 'regions_match': True, 'thresholds': windows,
                                    'arc_stacks': [{'count': n, 'frames': list(f)} for f, n in rule_a.most_common(12)],
                                    'node_stacks': [{'count': n, 'frames': list(f)} for f, n in rule_b.most_common(12)]}
    print(shape, 'attribution totals independently reproduced', dict(totals))
    for threshold, result in windows.items():
        print('threshold', threshold, 'samples', result['samples'], 'regions_percent', {k: round(v, 4) for k, v in result['percent'].items()}, 'cf_leaves', result['cf_leaves'])
    print('ARC stacks', json.dumps(report['attribution'][shape]['arc_stacks'], indent=2))
    print('NODE stacks', json.dumps(report['attribution'][shape]['node_stacks'][:3], indent=2))

(OUT / 'evidence-audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
