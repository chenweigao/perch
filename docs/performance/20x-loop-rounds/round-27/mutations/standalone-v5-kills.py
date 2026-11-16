#!/usr/bin/env python3
"""Standalone-pin kill proofs for the re-review's NFC-normalization mutants.

Adapted from the reviewer's harness (/tmp/perch-r27-recheck.36mF2N/recheck_native.py,
which loads sources/pin from git 28b3cb6): this variant loads the V5 pin and
product sources from git a2ac5bb, builds a standalone binary containing ONLY
checkRenderedSourceCache (plus the product module sources), and runs the two
mutants that survived v3. Expected: exit != 0 (killed by the v5 byte-level
assertions), proving the round-27 pin kills them WITHOUT relying on the
pre-existing round-12 hole probe that fires first in the full checks binary.
"""
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys

ROOT = Path('<worktree>')
OUT = ROOT / '.local/round27/mutations/standalone-v5'
OUT.mkdir(parents=True, exist_ok=True)
SWIFTC = '/home/<dev>/.local/swift/6.3.3/usr/bin/swiftc'
BUILD = ROOT / '.build/x86_64-unknown-linux-gnu/release'
ENV = dict(os.environ, TMPDIR=str(OUT), XDG_CACHE_HOME=str(OUT / 'cache'),
           SWIFT_BACKTRACE='enable=yes,interactive=no,color=no')
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
REV = subprocess.check_output(['git', '--no-optional-locks', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
assert REV.startswith('a2ac5bb'), REV

source_paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', REV, '--', 'Sources/WorkbenchCore'], cwd=ROOT, text=True).splitlines()
sources = {Path(rel).name: subprocess.check_output(['git', 'show', REV + ':' + rel], cwd=ROOT).decode() for rel in source_paths if rel.endswith('.swift')}
pin = subprocess.check_output(['git', 'show', REV + ':Tests/WorkbenchCoreTests/RenderedSourceCacheTests.swift'], cwd=ROOT).decode()
assert 'byteShape' in pin, 'pin must be the v5 byte-level version'

objects = (BUILD / 'WorkbenchChecks.product/Objects.LinkFileList').read_text().splitlines()
deps = [p for p in objects if '/WorkbenchCore.build/' not in p and '/WorkbenchChecks.build/' not in p]
common = ['-swift-version', '5', '-O', '-g', '-module-cache-path', str(OUT / 'module-cache'), '-I', str(BUILD / 'Modules')]
for checkout, rel in [('swift-cmark', 'extensions/include'), ('swift-cmark', 'src/include'),
                      ('swift-markdown', 'Sources/CAtomic/include'), ('swift-crypto', 'Sources/CXKCPShims/include'),
                      ('swift-crypto', 'Sources/CXKCP/include'), ('swift-crypto', 'Sources/CCryptoBoringSSL/include')]:
    inc = ROOT / '.build/checkouts' / checkout / rel
    common += ['-Xcc', '-fmodule-map-file=' + str(inc / 'module.modulemap'), '-Xcc', '-I' + str(inc)]

MAIN = '''import Foundation
@main struct Main {
    static func main() throws {
        setbuf(stdout, nil)
        try checkRenderedSourceCache()
    }
}
'''

results = {'head': REV, 'pin_sha256': hashlib.sha256(pin.encode()).hexdigest(),
           'cache_sha256': hashlib.sha256(sources['RenderedSourceCache.swift'].encode()).hexdigest(),
           'variants': {}}

def run_variant(name, replacements=None):
    folder = OUT / name
    folder.mkdir(exist_ok=True)
    chosen = sources.copy()
    chosen.update(replacements or {})
    paths = []
    for filename, content in chosen.items():
        dest = folder / filename
        dest.write_text(content)
        paths.append(str(dest))
    (folder / 'Pin.swift').write_text(pin.replace('import WorkbenchCore\n', ''))
    (folder / 'Main.swift').write_text(MAIN)
    response = folder / 'dependencies.txt'
    response.write_text('\n'.join(deps) + '\n')
    cmd = [SWIFTC, *common, '-whole-module-optimization', '-num-threads', '8', '-module-name', 'WorkbenchCore',
           '-parse-as-library', '-D', 'SWIFT_PACKAGE', '-D', 'SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE',
           '-lstdc++', *paths, str(folder / 'Pin.swift'), str(folder / 'Main.swift'),
           '@' + str(response), '-o', str(folder / 'run')]
    build = subprocess.run(cmd, cwd=folder, env=ENV, capture_output=True, text=True)
    if build.returncode != 0:
        results['variants'][name] = {'build_exit': build.returncode, 'build_tail': build.stderr[-2000:]}
        print(name, 'BUILD_FAIL', build.returncode)
        return
    run = subprocess.run([str(folder / 'run')], cwd=folder, env=ENV, capture_output=True, text=True, timeout=300)
    results['variants'][name] = {'build_exit': 0, 'shell_exit': run.returncode,
                                 'stdout_tail': run.stdout[-600:], 'stderr_tail': run.stderr[-1200:]}
    print(name, 'exit =', run.returncode, 'SURVIVED =', run.returncode == 0, flush=True)

cache = sources['RenderedSourceCache.swift']
hit = cache.replace('            return node.rendered', '            return node.rendered.precomposedStringWithCanonicalMapping')
assert hit != cache
run_variant('normalize-cache-hit-nfc-vs-v5', {'RenderedSourceCache.swift': hit})
rend = cache.replace('        let produced = produce()', '        let produced = produce().precomposedStringWithCanonicalMapping')
assert rend != cache
run_variant('normalize-render-nfc-vs-v5', {'RenderedSourceCache.swift': rend})
# control: unmutated v5 must PASS in the same harness
run_variant('v5-original-control')

(OUT / 'standalone-kill-receipt.json').write_text(json.dumps(results, indent=1, ensure_ascii=False) + '\n')
survived = [k for k, v in results['variants'].items() if v.get('shell_exit') == 0 and 'control' not in k]
control_ok = results['variants']['v5-original-control'].get('shell_exit') == 0
print('CONTROL_PASS =', control_ok, '| SURVIVED_MUTANTS =', survived or 'NONE')
