import hashlib
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'review-artifacts'
RELEASE = ROOT / '.build/x86_64-unknown-linux-gnu/release'
SWIFTC = '/home/<dev>/.local/swift/6.3.3/usr/bin/swiftc'
d = json.loads((RELEASE / 'description.json').read_text())
c = next(v for k, v in d['swiftCommands'].items() if 'WorkbenchCore' in k)
objects = (RELEASE / 'WorkbenchChecks.product/Objects.LinkFileList').read_text().splitlines()
noncore = [o for o in objects if '/WorkbenchCore.build/' not in o]
deps = [o for o in noncore if '/WorkbenchChecks.build/' not in o]
args = []
orig = iter(c['otherArguments'])
for arg in orig:
    if arg in ('-num-threads', '-emit-objc-header-path', '-module-cache-path'):
        next(orig)
    elif arg not in ('-serialize-diagnostics', '-parseable-output', '-emit-objc-header') and not arg.startswith('-j'):
        args.append(arg)
source = (ROOT / 'Sources/WorkbenchCore/ConversationSearch.swift').read_text()
base = subprocess.check_output(['git', 'show', '4c184e5:Sources/WorkbenchCore/ConversationSearch.swift'], cwd=ROOT, text=True)
base = base[base.index('public final class ConversationSearch'):base.index('public struct SessionNavigation')].replace('public final class ConversationSearch', 'public final class Round32ReviewSearch')
(OUT / 'ReviewBaseline.swift').write_text('import Foundation\n' + base)
(OUT / 'WindowBitsExports.swift').write_text('public func round33ReviewSameWindowBits(_ lhs: ArraySlice<KimiMessage>, _ rhs: ArraySlice<KimiMessage>) -> Bool { KimiMessage.sameWindowBits(lhs, rhs) }\npublic func round33ReviewSameWindow(_ lhs: ArraySlice<KimiMessage>, _ rhs: ArraySlice<KimiMessage>) -> Bool { KimiMessage.sameWindow(lhs, rhs) }\n')
receipts = {}

def run(cmd, log, env=None):
    with log.open('w') as f:
        proc = subprocess.run(cmd, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
    print(log.name, 'exit', proc.returncode, flush=True)
    return proc.returncode

for name in ('control', 'running-bypass'):
    directory = OUT / name
    directory.mkdir(exist_ok=True)
    text = source
    if name == 'running-bypass':
        old = '        if !suffixHits.isEmpty {\n            hits += suffixHits\n        }'
        assert text.count(old) == 1
        text = text.replace(old, '        if !suffixHits.isEmpty || running {\n            hits += suffixHits\n        }')
    variant_source = directory / 'ConversationSearch.swift'
    unchanged = variant_source.exists() and variant_source.read_text() == text
    variant_source.write_text(text)
    module = directory / 'WorkbenchCore.swiftmodule'
    obj = directory / 'WorkbenchCore.o'
    sources = [str(variant_source) if pathlib.Path(s).name == 'ConversationSearch.swift' else s for s in c['sources']]
    sources += [str(OUT / 'ReviewBaseline.swift'), str(OUT / 'WindowBitsExports.swift')]
    command = [SWIFTC, '-module-name', 'WorkbenchCore', '-I', c['importPath'], *args, '-module-cache-path', str(directory / 'ModuleCache'), '-c', *sources, '-o', str(obj), '-emit-module', '-emit-module-path', str(module)]
    receipts[name] = {'core_source_sha256': hashlib.sha256(variant_source.read_bytes()).hexdigest(), 'core_build_command': command}
    if not (unchanged and obj.exists() and module.exists()):
        assert run(command, directory / 'core-build.log') == 0
    else:
        print(name, 'reusing previously successful isolated core compile', flush=True)
    objectlist = directory / 'checks-objects.txt'
    objectlist.write_text('\n'.join(noncore + [str(obj)]) + '\n')
    checks = directory / 'WorkbenchChecks'
    link = [SWIFTC, '-lstdc++', '-L', str(RELEASE), '-o', str(checks), '-module-name', 'WorkbenchChecks', '-emit-executable', '-Xlinker', '--gc-sections', '-Xlinker', '--defsym', '-Xlinker', 'main=WorkbenchChecks_main', '-Xlinker', '-rpath=$ORIGIN', '@' + str(objectlist), '-target', 'x86_64-unknown-linux-gnu', '-g']
    assert run(link, directory / 'checks-link.log') == 0
    receipts[name]['checks_exit'] = run([str(checks)], directory / 'checks.log')
    checkstext = (directory / 'checks.log').read_text()
    receipts[name]['pass_count'] = sum(s.startswith('PASS') for s in checkstext.splitlines())
    receipts[name]['skip_count'] = sum(s.startswith('SKIP') for s in checkstext.splitlines())
    probe = directory / 'GuardProbe'
    clang_flags = []
    for index, argument in enumerate(args):
        if argument == '-Xcc':
            clang_flags.extend([argument, args[index + 1]])
    probecommand = [SWIFTC, '-lstdc++', '-O', '-g', '-swift-version', '5', '-parse-as-library', '-I', str(directory), '-I', c['importPath'], *clang_flags, str(OUT / 'GuardProbe.swift'), *deps, str(obj), '-o', str(probe)]
    assert run(probecommand, directory / 'probe-build.log') == 0
    env = dict(os.environ, REVIEW_REQUIRE_GUARD='1', SWIFT_BACKTRACE='enable=no')
    receipts[name]['probe_exit'] = run([str(probe)], directory / 'probe.log', env=env)
    print('summary', name, receipts[name]['checks_exit'], receipts[name]['pass_count'], receipts[name]['skip_count'], receipts[name]['probe_exit'], flush=True)
    (OUT / 'probe-receipts.json').write_text(json.dumps(receipts, indent=2) + '\n')
assert receipts['control']['checks_exit'] == receipts['control']['probe_exit'] == 0
assert receipts['running-bypass']['checks_exit'] == 0
assert receipts['running-bypass']['probe_exit'] != 0
print('PASS: running-bypass mutant survives complete original checks but dies on running=true consumer probe', flush=True)
