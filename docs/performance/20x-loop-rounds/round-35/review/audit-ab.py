import json, re, statistics, hashlib
from pathlib import Path
root = Path('/home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15/.local/round35')
output = {}
for platform, folder in [('linux', 'ab35v2'), ('macos', 'macos-ab-v2')]:
    summary = json.loads((root / f'{platform}-ab-v2-summary.json').read_text())
    mismatches, positives, raw_mismatches = [], [], []
    raw = {side: [{} for _ in range(6)] for side in ['baseline', 'candidate']}
    logs = []
    for side in raw:
        for i in range(6):
            def load(kind):
                p = root / folder / f'pair{i+1}-{side}-{kind}.log'
                logs.append({'path': str(p), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
                return p.read_text()
            dest = raw[side][i]
            for line in load('1').splitlines():
                vals = dict(re.findall(r'(\w+)=([0-9.]+)', line))
                for key in ['cold', 'append']:
                    dest[f'{key}@{vals["source_slots"]}'] = float(vals[f'{key}_median_ms'])
            for line in load('activity').splitlines():
                vals = dict(re.findall(r'(\w+)=([0-9.]+)', line))
                for key in ['edit_stats', 'running_ids', 'activity_init']:
                    if f'{key}_median_ms' in vals:
                        name = f'{key}@{vals["messages"]}' if 'turns' in vals else f'single_turn_activity@{vals["messages"]}'
                        dest[name] = float(vals[f'{key}_median_ms'])
            for item in json.loads(load('edit-lines'))['results']:
                key = f'edit{item.get("source_lines", item.get("lines", item.get("line_count")))}_{item["case"]}'
                if key not in summary:
                    key = next((k for k in summary if k.startswith('edit') and k.endswith('_'+item['case']) and str(item.get('lines', '')) in k), key)
                dest[key] = statistics.median(item['samples_ms'])
            for item in json.loads(load('presentation-token'))['results']:
                prefix = ('longtail' if item.get('scenario') == 'long-tail-stream' else 'token') + str(item['fixture_turns'])
                for field in item['samples'][0]:
                    if field.endswith('_ms'):
                        dest[f'{prefix}_{field}'] = statistics.median(s[field] for s in item['samples'])
            paging, breakdown = False, False
            for line in load('streaming').splitlines():
                if 'older_page_full_chain' in line: paging, breakdown = True, False
                if 'breakdown' in line: breakdown = True
                match = re.search(r'^\s+(\w+)\s+median_ms=\s*([0-9.]+)', line)
                if not match: continue
                name, value = match[1], float(match[2])
                if name == 'older_page_full_chain' or name == 'release_model_state': key = name
                elif paging: key = 'page_'+name
                elif breakdown: key = 'stage_'+name
                else: key = 'memory_keys' if name == 'memory_keys' else name
                dest[key] = value
    fields = 0
    for name, row in summary.items():
        b, c = row['baseline_samples'], row['candidate_samples']
        bm, cm = statistics.median(b), statistics.median(c)
        spread = max((max(x)/min(x)-1)*100 if min(x)>0 else 0 for x in [b,c])
        derived = dict(baseline_median=bm, candidate_median=cm, change_percent=(cm/bm-1)*100 if bm else 0,
                       max_spread_percent=spread, worst_pair_percent=max(((y/x-1)*100 for x,y in zip(b,c) if x>0), default=0))
        for field, value in derived.items():
            fields += 1
            if abs(value-row[field])>1e-9: mismatches.append([name, field, value, row[field]])
        if round(derived['change_percent'], 2)>round(spread,2): positives.append(name)
        for side, samples in [('baseline', b), ('candidate', c)]:
            for i, value in enumerate(samples):
                got = raw[side][i].get(name)
                if got is None or abs(got-value)>1e-10: raw_mismatches.append([name, side, i+1, got, value])
    check_counts = {}
    for side, file in [('baseline','checks-base.log'),('candidate','checks-cand.log')]:
        text = (root/folder/file).read_text()
        check_counts[side] = dict(PASS=len(re.findall(r'^PASS:',text,re.M)), SKIP=len(re.findall(r'^SKIP:',text,re.M)))
    output[platform] = dict(metrics=len(summary), recalculated_fields=fields, statistic_mismatches=mismatches,
        positives=positives, raw_mismatches=raw_mismatches, logs=logs, checks=check_counts,
        older_page=summary['older_page_full_chain'], reopen=summary['find_bar_reopen_query'])
Path('review-artifacts/ab-audit.json').write_text(json.dumps(output, indent=2))
for platform, row in output.items():
    print(platform, {k:v for k,v in row.items() if k not in ['logs', 'older_page', 'reopen', 'raw_mismatches']})
    print('raw mismatches', len(row['raw_mismatches']), row['raw_mismatches'][:12])
