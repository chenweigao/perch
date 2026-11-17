import sys
sys.dont_write_bytecode = True
import importlib.util
import io
import contextlib
import json
import hashlib
from collections import Counter
from pathlib import Path
root = Path(__file__).resolve().parents[1]
out = root/'review-artifacts'
spec = importlib.util.spec_from_file_location('archived',root/'docs/performance/20x-loop-rounds/round-39/attr/analyze_r39.py')
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
filters = dict(a.REGIONS)['setup-wire-decode']+['JSONSerialization','CFJSONSerialization']
result = {}
for r in [38,39]:
    xml = out/f'r{r}-streaming-time-profile.xml'
    rows = a.load(xml)
    frs = [f for _,f in rows]
    free = [fr for fr in frs if not any(p in f for f in fr for p in filters)]
    narrative = sum(any('ActivityNarrativeProjection' in f for f in fr) for fr in free)
    count = Counter(a.classify(fr) for fr in frs)
    oldargv = sys.argv
    sys.argv = ['analyze',str(xml),'streaming']
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf): a.main()
    sys.argv = oldargv
    printed = buf.getvalue()
    (out/f'r{r}-independent-streaming-attribution.txt').write_text(printed)
    archive = root/f'docs/performance/20x-loop-rounds/round-{r}/attr/streaming-attribution.txt'
    result[str(r)] = {'xml_sha256':hashlib.sha256(xml.read_bytes()).hexdigest(),'total':len(frs),'decode_ancestry':len(frs)-len(free),'decode_free':len(free),'narrative_inclusive':narrative,'narrative_inclusive_percent':100*narrative/len(free),'narrative_region':count['narrative'],'narrative_region_full_percent':100*count['narrative']/len(frs),'archived_streaming_output_exact_match':archive.read_text()==printed}
text1 = (root/'docs/performance/20x-loop-rounds/round-38/attr/r38-attr.job').read_text()
text2 = (root/'docs/performance/20x-loop-rounds/round-39/attr/r39-attr.job').read_text()
def harness(s, number):
    return s[s.index(f'func benchR{number}StreamProfile()'):s.index('\nSWIFTEOF', s.index(f'func benchR{number}StreamProfile()'))].replace(f'R{number}', 'RN').replace(f'r{number}', 'rn')
result['harness_code_exact_after_round_renaming'] = harness(text1,38)==harness(text2,39)
result['interpretation'] = 'Inclusive是各自decode-free分母，region是各自full-trace分母。跨采样份额与A/B墙钟不得直接等同。两份harness代码轮名归一后相同，仅支持同类场景下方向性旁证；205 vs bench35更新、1 vs bench2 getter、find与未计时model.update等差异未被fidelity比率消除。'
(out/'r38-r39-chain-audit.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(result,ensure_ascii=False,indent=2))
