from pathlib import Path
import hashlib
import json

out = Path(__file__).resolve().parent
findings = json.loads((out / 'review-findings.json').read_text())
assert findings['verdict'] == 'BLOCKING 4'
assert findings['blocking_count'] == sum(f['severity'].startswith('BLOCKING') for f in findings['findings'])
assert findings['verification']['ci']['completed_successfully'] == 15
assert json.loads((out / 'portable/results.json').read_text())['status'] == 'passed'
files = []
for p in sorted(out.rglob('*')):
    if p.is_file() and p.name != 'artifact-manifest.json':
        files.append({'path': str(p), 'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
manifest = {'verdict': findings['verdict'], 'root': str(out), 'files': files,
            'cleanup': ['Temporary SwiftPM scratch dependency/build tree removed', 'Temporary compiled probe and object list removed'],
            'preserved': 'Review scripts, source probe, raw logs, independent XML calculations and CI/portable receipts; original XML remains read-only in author worktree'}
(out / 'artifact-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f"Validated verdict; retained {len(files)} artifact files plus manifest under {out}")
