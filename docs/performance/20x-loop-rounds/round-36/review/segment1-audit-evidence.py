import hashlib
import json
import math
import re
import statistics
from pathlib import Path

root = Path(__file__).resolve().parent.parent
out = Path(__file__).resolve().parent
ab = root / 'docs/performance/20x-loop-rounds/round-36/ab'
audit = {}
for platform in ('macos', 'linux'):
    file = ab / f'{platform}-ab-v2-summary.json'
    data = json.loads(file.read_text())
    mismatches, positives, computed = [], [], {}
    for name, row in data.items():
        b, c = row['baseline_samples'], row['candidate_samples']
        if len(b) != 6 or len(c) != 6:
            mismatches.append({'metric': name, 'sample_count': [len(b), len(c)]})
        bm, cm = statistics.median(b), statistics.median(c)
        def spread(values):
            return (max(values) - min(values)) / min(values) * 100 if min(values) > 0 else 0.0
        change = (cm / bm - 1) * 100 if bm else float('nan')
        stats = {'baseline_median': bm, 'candidate_median': cm,
                 'change_percent': change, 'max_spread_percent': max(spread(b), spread(c)),
                 'worst_pair_percent': max(((ci-bi)/bi*100 for bi, ci in zip(b,c) if bi > 0), default=0)}
        for key, value in stats.items():
            stored = row[key]
            if not ((math.isnan(value) and math.isnan(stored)) or math.isclose(value, stored, abs_tol=1e-9, rel_tol=1e-9)):
                mismatches.append({'metric': name, 'field': key, 'computed': value, 'stored': stored})
        stats['all_pairs_improve'] = all(ci < bi for bi, ci in zip(b, c))
        stats['range_separation_improve'] = max(c) < min(b)
        stats['range_separation_regress'] = min(c) > max(b)
        stats['rounded_positive_beyond_spread'] = round(change, 2) > round(stats['max_spread_percent'], 2)
        if stats['rounded_positive_beyond_spread']:
            positives.append(name)
        computed[name] = stats
    log = (ab / ('macos-perfrunner-concat.log' if platform == 'macos' else 'linux-ab-v2-driver.log')).read_text()
    timed = re.findall(r'pair=(\d+) variant=(baseline|candidate) mode=([^\s]+) exit=(\d+)', log)
    audit[platform] = {'summary_sha256': hashlib.sha256(file.read_bytes()).hexdigest(), 'metrics': len(data),
                       'statistics_fields_checked': len(data)*5, 'mismatches': mismatches,
                       'positives_beyond_spread': positives, 'timer_run_count': len(timed),
                       'timer_nonzero_exits': [r for r in timed if r[-1] != '0'], 'computed': computed}

attr_dir = root / 'docs/performance/20x-loop-rounds/round-36/attr'
text = (attr_dir / 'paging-attribution.txt').read_text()
counts = [int(s) for s in re.findall(r'^\s+(\d+)\s+[\d.]+%\s+[a-z][a-z0-9-]+$', text.split('== phase [warm]')[0], re.M)]
old = (root / 'docs/performance/20x-loop-rounds/round-34/attr/analyze_r34.py').read_text()
new = (attr_dir / 'analyze_r36.py').read_text()
def strip_doc(s):
    return re.sub(r'\A(#![^\n]+\n)?""".*?"""', '', s, count=1, flags=re.S)
attr = {'prepend_samples':16925, 'region_sum':sum(counts), 'unprinted_region_samples':16925-sum(counts), 'print_threshold_percent':0.05,
        'analyzer_identical_except_docstring':strip_doc(old)==strip_doc(new),
        'hash_claim_samples':1129,'hash_claim_fraction_of_prepend':1129/16925*100,
        'claimed_joined_sum':1129+550+385+49,'claimed_joined_fraction':(1129+550+385+49)/16925*100,
        'archived_deep_hash_group':1443,'archived_direct_joined_hash':259,
        'archived_deep_String_hash_bucket':1007,
        'claimed_67_8_denominator_implied':1129/0.678,
        'limitation':'Archived deep table stops at String.hash(into:); 1129 and its claimed total-hash denominator are not independently recoverable from committed tables. Raw Time Profiler XML is not in candidate.'}
(out/'ab-audit.json').write_text(json.dumps(audit, ensure_ascii=False, indent=2)+'\n')
(out/'attribution-audit.json').write_text(json.dumps(attr, ensure_ascii=False, indent=2)+'\n')
for platform, r in audit.items():
    print(platform, 'metrics',r['metrics'],'fields',r['statistics_fields_checked'],'mismatches',len(r['mismatches']),'positives',r['positives_beyond_spread'])
    print('older_page_full_chain', json.dumps(r['computed']['older_page_full_chain']))
print('attribution',json.dumps(attr))
