import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / 'review-artifacts'
mutations = json.loads((ART / 'mutation-results.json').read_text())
trace = (ART / 'd2-trace-checks.log').read_text()
section = trace.split('REVIEW_D2_BEGIN\n', 1)[1].split('REVIEW_D2_END', 1)[0]
conversions = re.findall(r'REVIEW_CONVERT query=([^\n]+) id=([^\n]+)', section)
reuses = re.findall(r'REVIEW_REUSE query=([^\n]+) id=([^\n]+)', section)
retention = json.loads((ART / 'retention-results.json').read_text())
final_log = (ART / 'final-control-checks.log').read_text()
assert retention.get('checks_exit') == 0, retention
assert sum(s.startswith('PASS:') for s in final_log.splitlines()) == 108
assert any(c['case'] == 'restored-control' and c.get('checks_exit') == 0 for c in mutations)
final_hash = hashlib.sha256((ART / 'build/x86_64-unknown-linux-gnu/release/WorkbenchChecks').read_bytes()).hexdigest()
shutil.rmtree(ART / 'build')
status = subprocess.check_output(['git', 'status', '--short', '--untracked-files=all'], cwd=ROOT, text=True)
diff = subprocess.check_output(['git', 'diff', '--name-only'], cwd=ROOT, text=True)
assert diff == '', diff
assert retention.get('checks_exit') == 0, retention
assert any(c['case'] == 'restored-control' and c.get('checks_exit') == 0 for c in mutations)
assert all(p.startswith('?? review-artifacts/') for p in status.splitlines()), status
receipt = {
    'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'tracked_diff_empty': diff == '',
    'untracked_paths': status.splitlines(),
    'd2_conversion_events': conversions,
    'd2_reuse_events': reuses,
    'final_pass_lines': sum(s.startswith('PASS:') for s in final_log.splitlines()),
    'final_skip_lines': [s for s in final_log.splitlines() if s.startswith('SKIP:')],
    'final_binary_sha256': final_hash,
    'temporary_build_output_removed': True,
    'retention_probes': retention['probes'],
    'mutations': mutations,
}
(ART / 'final-receipt.json').write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + '\n')
print(json.dumps({k: v for k, v in receipt.items() if k not in ['mutations', 'untracked_paths']}, indent=2, ensure_ascii=False))
