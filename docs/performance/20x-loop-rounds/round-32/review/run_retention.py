import difflib
import json
import os
from pathlib import Path
import resource
import subprocess

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / 'review-artifacts'
TEST = ROOT / 'Tests/WorkbenchCoreTests/ConversationPrefixCacheTests.swift'
ORIGINAL = TEST.read_text()
SWIFT = '/home/<dev>/.local/swift/6.3.3/usr/bin/swift'
BUILD = ART / 'build'
BINARY = BUILD / 'x86_64-unknown-linux-gnu/release/WorkbenchChecks'
ENV = dict(os.environ, PATH=str(Path(SWIFT).parent) + ':' + os.environ['PATH'])
ENV.pop('WORKBENCH_BENCH', None)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
assert subprocess.check_output(['git', 'diff', '--name-only'], cwd=ROOT, text=True) == '', 'do not overlap a running mutation case'
changed = ORIGINAL.replace('    let opts = ConversationFindOptions()\n', '    let opts = ConversationFindOptions()\n' + (ART / 'retention-probes.swift').read_text() + (ART / 'mechanism-pin-proposal.swift').read_text(), 1)
(ART / 'retention-probes.patch').write_text(''.join(difflib.unified_diff(ORIGINAL.splitlines(True), changed.splitlines(True), fromfile=str(TEST.relative_to(ROOT)), tofile=str(TEST.relative_to(ROOT)))))
try:
    TEST.write_text(changed)
    with (ART / 'retention-probes-build.log').open('w') as log:
        build = subprocess.run([SWIFT, 'build', '-c', 'release', '--product', 'WorkbenchChecks', '--scratch-path', str(BUILD), '-j', '4'], cwd=ROOT, env=ENV, stdout=log, stderr=subprocess.STDOUT)
    result = {'build_exit': build.returncode}
    if build.returncode == 0:
        with (ART / 'retention-probes-checks.log').open('w') as log:
            checks = subprocess.run([str(BINARY)], cwd=ROOT, env=ENV, stdout=log, stderr=subprocess.STDOUT)
        result['checks_exit'] = checks.returncode
        result['probes'] = [s for s in (ART / 'retention-probes-checks.log').read_text().splitlines() if s.startswith('REVIEW_')]
    (ART / 'retention-results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2), flush=True)
finally:
    TEST.write_text(ORIGINAL)
with (ART / 'final-control-build.log').open('w') as log:
    build = subprocess.run([SWIFT, 'build', '-c', 'release', '--product', 'WorkbenchChecks', '--scratch-path', str(BUILD), '-j', '4'], cwd=ROOT, env=ENV, stdout=log, stderr=subprocess.STDOUT)
if build.returncode == 0:
    with (ART / 'final-control-checks.log').open('w') as log:
        checks = subprocess.run([str(BINARY)], cwd=ROOT, env=ENV, stdout=log, stderr=subprocess.STDOUT)
    print(f'FINAL_CONTROL build={build.returncode} checks={checks.returncode}', flush=True)
else:
    print(f'FINAL_CONTROL build={build.returncode}', flush=True)
