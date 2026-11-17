import collections
import importlib.util
import json
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('r34', root / 'docs/performance/20x-loop-rounds/round-34/attr/analyze_r34.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
xml = Path(sys.argv[1])
out = root / 'review-artifacts'

def stats(fs):
    return {'samples': len(fs), 'regions': dict(collections.Counter(m.classify(f) for f in fs).most_common())}

def product(frames):
    for f in frames[1:]:
        if any(p in f for p in ['History.', 'HistoryTurn.', 'ToolVisibilityProjection', 'KimiMessage', 'ConversationPresentationModel', 'ActivityNarrativeProjection', 'AppLanguage', 'JSONValue', 'ConversationActivity', 'benchR34', 'L(']):
            return f
    return '<unresolved>'

paging = m.load(xml / 'paging-time-profile.xml')
frames = [f for t, f in paging]
marks = [m.marker(f) for f in frames]
nexts, prevs = [None] * len(marks), [None] * len(marks)
last = None
for i in range(len(marks) - 1, -1, -1):
    nexts[i] = last
    if marks[i] != '.': last = marks[i]
last = None
for i, mark in enumerate(marks):
    prevs[i] = last
    if mark != '.': last = mark
np = [f for i, f in enumerate(frames) if (marks[i] if marks[i] != '.' else nexts[i]) == 'P']
pp = [f for i, f in enumerate(frames) if (marks[i] if marks[i] != '.' else prevs[i]) == 'P']
false_warm = [f for f in np if any('canReuse' in x for x in f) and any('KimiMessage.sameWindow' in x for x in f)]
mechanical = [f for f in np if m.classify(f) in ['string-hash', 'dict-find', 'string-compare']]
consumers = collections.Counter(product(f) for f in mechanical)
by_bucket = {b: dict(collections.Counter(product(f) for f in np if m.classify(f) == b).most_common(18))
             for b in ['string-hash', 'dict-find', 'string-compare', 'utf16-bridge']}

stream = m.load(xml / 'streaming-time-profile.xml')
decode_pats = ['JSONSerialization', 'CFJSONSerialization', 'JSONDecoder', 'JSONScanner', 'KimiWire', 'init(from:', 'KeyedDecodingContainer', 'UnkeyedDecodingContainer', 'SingleValueDecodingContainer']
def has(fr, pats): return any(p in f for f in fr for p in pats)

def stream_slice(minimum):
    allf = [f for t, f in stream if t > minimum * 1e9]
    clean = [f for f in allf if not has(f, decode_pats)]
    find = [f for f in clean if has(f, ['ConversationSearch', 'ConversationEntryCache', 'ConversationPrefixCache', 'RenderedSourceCache'])]
    find_dd = [f for f in find if has(f, ['ReplyDocument.linkMatches', 'langid', 'DDScanner', 'DDLexer', 'DDToken', 'computeLexems', 'linkMatches'])]
    narrative = [f for f in clean if has(f, ['ActivityNarrativeProjection'])]
    return {'all_samples': len(allf), 'decode_free_samples': len(clean), 'narrative_inclusive_samples': len(narrative),
            'narrative_percent_decode_free': 100 * len(narrative) / len(clean),
            'find_inclusive_samples': len(find), 'find_percent_decode_free': 100 * len(find) / len(clean),
            'find_dd_inclusive_samples': len(find_dd), 'find_regions': stats(find)['regions']}

result = {'paging': {'next_marker_prepend': stats(np), 'previous_marker_prepend_sensitivity_only': stats(pp),
                     'proven_warm_canReuse_sameWindow_in_prepend': len(false_warm),
                     'mechanical_samples': len(mechanical), 'mechanical_percent_prepend': 100 * len(mechanical) / len(np),
                     'mechanical_nearest_product_consumers': dict(consumers.most_common(20)), 'consumers_by_bucket': by_bucket},
          'streaming': {str(t): stream_slice(t) for t in [0, 2, 3, 5, 10]}}
(out / 'followup-audit.json').write_text(json.dumps(result, indent=2) + '\n')
(out / 'paging-proven-warm-misclassification.txt').write_text('\n\n'.join('\n'.join(f) for f in false_warm[:10]))
print(json.dumps(result, indent=2))
