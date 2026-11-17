import sys
sys.dont_write_bytecode = True
import importlib.util
import json
import re
import statistics
import hashlib
from collections import Counter
from pathlib import Path

root = Path(__file__).resolve().parents[1]
out = root / 'review-artifacts'
attr = root / 'docs/performance/20x-loop-rounds/round-39/attr'
spec = importlib.util.spec_from_file_location('archived_analyzer', attr / 'analyze_r39.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
rows = a.load(out / 'r39-streaming-time-profile.xml')
frames = [f for _, f in rows]
wire_patterns = dict(a.REGIONS)['setup-wire-decode']
filters = {
    'wire-region-patterns': wire_patterns,
    'wire-plus-json': wire_patterns + ['JSONSerialization', 'CFJSONSerialization'],
    'warm-markers': list(a.WARM_MARKERS),
    'wire-json-apply': wire_patterns + ['JSONSerialization', 'CFJSONSerialization', 'KimiConversation.apply', 'KimiEvent'],
}
filter_counts = {k: sum(any(p in f for f in fr for p in pats) for fr in frames) for k, pats in filters.items()}
free = [fr for fr in frames if not any(p in f for f in fr for p in filters['wire-plus-json'])]
regions = Counter(a.classify(fr) for fr in free)
functions = {
    'displayMessages.getter': ['displayMessages.getter'],
    'KimiMessage.sameWindow': ['KimiMessage.sameWindow'],
    'TV.canReuse': ['canReuse'],
    'TV.projectTurns': ['projectTurns'],
    'TV.Pass.normalize': ['ToolVisibilityProjection.Pass.normalize'],
    'History.presented': ['History.presented'],
    'History.joined': ['History.joined'],
    'joinedIncremental': ['joinedIncremental'],
    'History.init': ['History.init'],
    'Input.equal': ['ConversationPresentationModel.Input.=='],
    'model.update': ['ConversationPresentationModel.update'],
    'Snapshot.presented': ['Snapshot.presented'],
    'ConversationActivity.init': ['ConversationActivity.init'],
    'TimelineEntry.make': ['ConversationTimelineEntry.make'],
    'ActivityNarrative': ['ActivityNarrativeProjection'],
    'NarrativeSteps': ['NarrativeTextCache.steps'],
    'NarrativeStageAssembly': ['ActivityNarrativeProjection.make'], 
    'NarrativeTextCache': ['NarrativeTextCache'],
    'NarrativePhaseScan': ['NarrativePhaseScan'],
    'ConversationSearch.search': ['ConversationSearch.search'],
    'resolution-memo-hit-path': ['NarrativeTextCache.resolution'],
}
inclusive = {k: sum(any(p in f for f in fr for p in pats) for fr in free) for k, pats in functions.items()}
checks = []
for name in ['decode-free-composition.txt', 'streaming-attribution.txt']:
    n = len(free) if name.startswith('decode') else len(frames)
    for line in (attr / name).read_text().splitlines():
        m = re.match(r'\s*(\d+)\s+([\d.]+)%\s+(.+)', line)
        if m:
            count, percent, label = int(m[1]), float(m[2]), m[3]
            calculated = round(count * 100 / n, 2)
            checks.append({'file': name, 'label': label, 'count': count, 'printed': percent, 'calculated': calculated, 'match': calculated == percent})
archive_regions = {}
archive_inclusive = {}
section = ''
for line in (attr / 'decode-free-composition.txt').read_text().splitlines():
    if 'innermost-region' in line: section = 'regions'
    if 'product-function' in line: section = 'inclusive'
    m = re.match(r'\s*(\d+)\s+([\d.]+)%\s+(.+)', line)
    if m:
        (archive_regions if section == 'regions' else archive_inclusive)[m[3]] = int(m[1])
region_match = dict(regions) == archive_regions
inclusive_comparison = {k: {'archived': v, 'recomputed': inclusive.get(k), 'match': inclusive.get(k) == v} for k, v in archive_inclusive.items()}
union_validation = sum(any('sameWindow' in f or 'canReuse' in f for f in fr) for fr in free)
consumer_breakdown = {}
for region in ['arc-copy', 'utf16-bridge', 'narrative']:
    bucket = [fr for fr in free if a.classify(fr) == region]
    consumer_breakdown[region] = {'total': len(bucket), 'inclusive_membership': {k: sum(any(p in f for f in fr for p in pats) for fr in bucket) for k,pats in functions.items()}}
all_counter = Counter(a.classify(fr) for fr in frames)
archive_streaming = {}
for line in (attr / 'streaming-attribution.txt').read_text().split('-- top leaves --')[0].splitlines():
    m = re.match(r'\s*(\d+)\s+([\d.]+)%\s+(.+)', line)
    if m: archive_streaming[m[3]] = int(m[1])
results = {
    'xml_sha256': hashlib.sha256((out / 'r39-streaming-time-profile.xml').read_bytes()).hexdigest(),
    'total': len(frames), 'filter_counts': filter_counts, 'decode_free': len(free),
    'regions': dict(regions), 'regions_exact_match': region_match,
    'listed_regions_exact_match': all(regions.get(k) == v for k,v in archive_regions.items()),
    'unlisted_regions': {k: v for k,v in regions.items() if k not in archive_regions},
    'raw_narrative_name_match': sum(any('ActivityNarrative' in f for f in fr) for fr in free),
    'all_trace_regions': dict(all_counter), 'all_trace_regions_exact_match': dict(all_counter) == archive_streaming,
    'inclusive': inclusive, 'inclusive_comparison': inclusive_comparison,
    'percentage_checks': checks, 'percentage_mismatches': [c for c in checks if not c['match']],
    'region_sum': sum(archive_regions.values()), 'region_remainder': len(free)-sum(archive_regions.values()),
    'validation_union': {'count': union_validation, 'percent': union_validation*100/len(free)},
    'consumer_breakdown': consumer_breakdown,
    'fidelity_ratio': 1.824/(1.13+0.49),
    'harness_change_percent': (0.824/1.069-1)*100,
}
(out / 'attribution-audit.json').write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({k: results[k] for k in ['total','filter_counts','decode_free','regions_exact_match','all_trace_regions_exact_match','inclusive_comparison','percentage_mismatches','region_remainder','validation_union','fidelity_ratio','harness_change_percent','consumer_breakdown']}, ensure_ascii=False, indent=2))

historical = []
for round_n in [35, 36, 38]:
    for path in sorted((root / f'docs/performance/20x-loop-rounds/round-{round_n}/ab').glob('*summary.json')):
        data = json.loads(path.read_text())
        for name in ['chain_total','older_page_full_chain','stage_narrative','presentation_update']:
            if name not in data: continue
            d = data[name]
            b, c = d['baseline_samples'], d['candidate_samples']
            bm, cm = statistics.median(b), statistics.median(c)
            spread = max((max(v)-min(v))/min(v)*100 if min(v) else 0 for v in [b,c])
            historical.append({'file': str(path.relative_to(root)), 'metric':name,'base':bm,'cand':cm,'change':(cm/bm-1)*100,'spread':spread,'printed_spread':d['max_spread_percent'],'spread_match':abs(spread-d['max_spread_percent'])<0.011})
(out / 'historical-spread-audit.json').write_text(json.dumps(historical, indent=2)+'\n')
print('HISTORICAL_MAC_CHAIN', json.dumps([r for r in historical if 'macos' in r['file'] and r['metric']=='chain_total']))
