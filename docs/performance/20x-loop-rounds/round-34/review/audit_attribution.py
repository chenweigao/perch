import collections
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('r34', ROOT / 'docs/performance/20x-loop-rounds/round-34/attr/analyze_r34.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
XML = Path(sys.argv[1])
out = ROOT / 'review-artifacts'

def pct(n, d):
    return round(100 * n / d, 6) if d else 0

def counts(frames):
    return dict(collections.Counter(m.classify(f) for f in frames).most_common())

def inclusive(frames, pats):
    return [f for f in frames if any(p in name for name in f for p in pats)]

result = {}
for shape in ['paging', 'streaming']:
    path = XML / f'{shape}-time-profile.xml'
    raw = subprocess.check_output([sys.executable, str(ROOT / 'docs/performance/20x-loop-rounds/round-34/attr/analyze_r34.py'), str(path), shape], text=True)
    (out / f'recomputed-{shape}.txt').write_text(raw)
    expected = (ROOT / f'docs/performance/20x-loop-rounds/round-34/attr/{shape}-attribution.txt').read_text()
    rows = m.load(path)
    frames = [f for t, f in rows]
    info = {'xml_sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'xml_bytes': path.stat().st_size,
            'samples': len(rows), 'archived_output_exact_match': raw == expected,
            'first_time': rows[0][0], 'last_time': rows[-1][0],
            'monotonic_sample_times': all(a[0] <= b[0] for a, b in zip(rows, rows[1:])),
            'all_regions': counts(frames)}
    if shape == 'paging':
        marks = [m.marker(f) for f in frames]
        nexts, lasts = [None] * len(marks), [None] * len(marks)
        last = None
        for i in range(len(marks) - 1, -1, -1):
            nexts[i] = last
            if marks[i] != '.':
                last = marks[i]
        last = None
        for i, mark in enumerate(marks):
            lasts[i] = last
            if mark != '.':
                last = mark
        phase = [mark if mark != '.' else (nexts[i] or 'J') for i, mark in enumerate(marks)]
        prepend = [f for f, p in zip(frames, phase) if p == 'P']
        disagreements = [i for i, mark in enumerate(marks) if mark == '.' and nexts[i] and lasts[i] and nexts[i] != lasts[i]]
        runs = []
        for i, p in enumerate(phase):
            if i == 0 or p != phase[i - 1]:
                runs.append({'phase': p, 'start': i, 'first_time': rows[i][0], 'samples': 0})
            runs[-1]['samples'] += 1
            runs[-1]['last_time'] = rows[i][0]
        info.update({'marker_counts': dict(collections.Counter(marks)), 'phase_counts': dict(collections.Counter(phase)),
                     'lookahead_previous_marker_disagreement': len(disagreements),
                     'disagreement_percent_of_all': pct(len(disagreements), len(rows)), 'runs': runs,
                     'prepend_inclusive': {p: {'samples': len(inclusive(prepend, [p])), 'percent': pct(len(inclusive(prepend, [p])), len(prepend))}
                         for p in ['ActivityNarrativeProjection', 'ConversationTimelineEntry.make', 'ConversationPresentationModel.update', 'ToolVisibilityProjection.projectTurns', 'History.joined', 'History.init']}})
        (out / 'paging-boundary-examples.txt').write_text('\n\n'.join(
            f'index={i} time={rows[i][0]} prev={lasts[i]} next={nexts[i]}\n' + '\n'.join(frames[i])
            for i in disagreements[:15]))
    else:
        decode_pats = ['JSONSerialization', 'CFJSONSerialization', 'JSONDecoder', 'JSONScanner', 'KimiWire', 'init(from:', 'KeyedDecodingContainer', 'UnkeyedDecodingContainer', 'SingleValueDecodingContainer']
        decode = inclusive(frames, decode_pats)
        clean = [f for f in frames if not any(p in name for name in f for p in decode_pats)]
        mismatch = [f for f in decode if m.classify(f) not in ['setup-json', 'setup-wire-decode']]
        find = inclusive(frames, ['ConversationSearch', 'ConversationPrefixCache', 'ConversationEntryCache', 'RenderedSourceCache'])
        cf = [f for f in frames if m.classify(f) == 'cf-match']
        real_match = inclusive(cf, ['CFStringFind', 'CFStringFold', 'langid', 'DDScanner', 'DDLexer'])
        info.update({'inclusive_decode_samples': len(decode), 'inclusive_decode_percent': pct(len(decode), len(rows)),
                     'decode_samples_outside_setup': len(mismatch), 'decode_outside_setup_regions': counts(mismatch),
                     'decode_free_samples': len(clean), 'decode_free_regions': counts(clean),
                     'find_inclusive_samples': len(find), 'find_inclusive_percent_all': pct(len(find), len(rows)),
                     'find_inclusive_percent_decode_free': pct(len(inclusive(clean, ['ConversationSearch', 'ConversationPrefixCache', 'ConversationEntryCache', 'RenderedSourceCache'])), len(clean)),
                     'find_inclusive_regions': counts(find),
                     'cf_bucket_samples': len(cf), 'cf_with_real_match_frames': len(real_match),
                     'cf_bucket_leaves': dict(collections.Counter(f[0] for f in cf).most_common(15)),
                     'narrative_inclusive_all': len(inclusive(frames, ['ActivityNarrativeProjection'])),
                     'narrative_inclusive_decode_free': len(inclusive(clean, ['ActivityNarrativeProjection']))})
        (out / 'streaming-decode-residual-examples.txt').write_text('\n\n'.join('\n'.join(f) for f in mismatch[:12]))
        (out / 'streaming-cf-examples.txt').write_text('\n\n'.join('\n'.join(f) for f in cf if not any(p in name for name in f for p in ['CFStringFind', 'CFStringFold', 'langid', 'DDScanner', 'DDLexer']))[:18000])
    result[shape] = info
(out / 'attribution-audit.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: {a: b for a, b in v.items() if a not in ['runs', 'all_regions', 'cf_bucket_leaves', 'find_inclusive_regions']} for k, v in result.items()}, indent=2))
