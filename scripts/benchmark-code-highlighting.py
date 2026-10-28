#!/usr/bin/env python3
"""Alternate fixed-input baseline/candidate color scheduling, outside UI/frame timing."""
import argparse, hashlib, json, pathlib, platform, subprocess
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline', required=True)
p.add_argument('--runs', type=int, default=3)
p.add_argument('--output', type=pathlib.Path, required=True)
a = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
out = a.output.resolve(); out.mkdir(parents=True, exist_ok=False)
source = root / 'Sources/AgentWorkbench/CodeHighlighting.swift'
baseline = subprocess.check_output(['git', 'show', a.baseline + ':Sources/AgentWorkbench/CodeHighlighting.swift'], cwd=root, text=True)
baseline = baseline.replace('private var cacheBytes = 0', 'private(set) var cacheBytes = 0')
if 'static func engine(for source:' not in baseline:
    baseline += '\nextension CodeHighlighter { static func engine(for source: String) -> CodeHighlighter { shared } }\n'
base = out / 'Baseline.swift'; base.write_text(baseline)
executables = {}
for name, code in [('baseline', base), ('candidate', source)]:
    app = out / (name + '.app'); binary = app / 'Contents/MacOS/Benchmark'
    binary.parent.mkdir(parents=True)
    subprocess.run([str(root / 'scripts/prepare-highlight.sh'), str(app / 'Contents/Resources')], cwd=root, check=True)
    subprocess.run(['swiftc', '-O', '-whole-module-optimization', '-swift-version', '5', '-parse-as-library',
        '-target', platform.machine() + '-apple-macosx26.0', str(code), str(root / 'Tests/CodeHighlightBenchmark/Main.swift'),
        '-o', str(binary)], cwd=root, check=True)
    executables[name] = binary
metadata = {'baseline': subprocess.check_output(['git', 'rev-parse', a.baseline], cwd=root, text=True).strip(),
    'candidate_source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'configuration': '-O -whole-module-optimization; Swift 5; macOS 26 target',
    'os': platform.platform(), 'compiler': subprocess.check_output(['swift', '--version'], text=True).strip(),
    'scope': 'background token scheduling and cache reuse; no file IO, window layout, presented frames or trackpad timing'}
(out / 'metadata.json').write_text(json.dumps(metadata, indent=2))
with (out / 'matched.jsonl').open('w') as log:
    for run in range(a.runs):
        for name in (['baseline', 'candidate'] if run % 2 == 0 else ['candidate', 'baseline']):
            raw = subprocess.check_output([str(executables[name]), str(root / 'remote/native-agent-service.py')], text=True, timeout=60)
            row = dict(json.loads(raw), arm=name, run=run + 1)
            log.write(json.dumps(row) + '\n'); log.flush(); print(json.dumps(row), flush=True)
