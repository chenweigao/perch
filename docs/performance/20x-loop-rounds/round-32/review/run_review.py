import difflib
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / 'review-artifacts'
BUILD = ART / 'build'
SWIFT = '/home/<dev>/.local/swift/6.3.3/usr/bin/swift'
BINARY = BUILD / 'x86_64-unknown-linux-gnu/release/WorkbenchChecks'
FILES = ['Sources/WorkbenchCore/ConversationSearch.swift',
         'Sources/WorkbenchCore/ConversationPrefixCache.swift',
         'Tests/WorkbenchCoreTests/ConversationPrefixCacheTests.swift']
ORIGINAL = {p: (ROOT / p).read_text() for p in FILES}
ENV = dict(os.environ, PATH=str(Path(SWIFT).parent) + ':' + os.environ['PATH'])
ENV.pop('WORKBENCH_BENCH', None)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
results = []


def restore():
    for path, content in ORIGINAL.items():
        if (ROOT / path).read_text() != content:
            (ROOT / path).write_text(content)


def stop(signum, frame):
    raise KeyboardInterrupt(f'signal {signum}')


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def replace(files, path, old, new):
    assert files[path].count(old) == 1, (path, old)
    files[path] = files[path].replace(old, new)


def run_case(name, changes=None):
    restore()
    changed = dict(ORIGINAL)
    if changes:
        changes(changed)
    patch = ''
    for path, content in changed.items():
        if content != ORIGINAL[path]:
            (ROOT / path).write_text(content)
            patch += ''.join(difflib.unified_diff(ORIGINAL[path].splitlines(True), content.splitlines(True), fromfile=path, tofile=path))
    if patch:
        (ART / f'{name}.patch').write_text(patch)
    print(f'START {name}', flush=True)
    started = time.monotonic()
    with (ART / f'{name}-build.log').open('w') as log:
        build = subprocess.run([SWIFT, 'build', '-c', 'release', '--product', 'WorkbenchChecks', '--scratch-path', str(BUILD), '-j', '4'], cwd=ROOT, env=ENV, stdout=log, stderr=subprocess.STDOUT)
    result = {'case': name, 'build_exit': build.returncode}
    if build.returncode == 0:
        result['binary_sha256'] = hashlib.sha256(BINARY.read_bytes()).hexdigest()
        with (ART / f'{name}-checks.log').open('w') as log:
            checks = subprocess.run([str(BINARY)], cwd=ROOT, env=ENV, stdout=log, stderr=subprocess.STDOUT)
        result['checks_exit'] = checks.returncode
        result['pass_lines'] = sum(line.startswith('PASS:') for line in (ART / f'{name}-checks.log').read_text().splitlines())
    result['seconds'] = round(time.monotonic() - started, 3)
    results.append(result)
    (ART / 'mutation-results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    restore()
    return result


SEARCH = FILES[0]
PREFIX = FILES[1]
TESTS = FILES[2]


def bypass(files):
    replace(files, SEARCH, '} else if let node = prefixCache.node(forKey: prefixKey, prefix: prefix) {', '} else if false, let node = prefixCache.node(forKey: prefixKey, prefix: prefix) {')


def canonical(files):
    replace(files, PREFIX,
            'bytes.withUnsafeBufferPointer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }',
            'hasher.combine(String(decoding: bytes, as: UTF8.self))')
    replace(files, PREFIX,
            'static func == (lhs: Key, rhs: Key) -> Bool { lhs.bytes == rhs.bytes }',
            'static func == (lhs: Key, rhs: Key) -> Bool { String(decoding: lhs.bytes, as: UTF8.self) == String(decoding: rhs.bytes, as: UTF8.self) }')


def skip_verification(files):
    replace(files, PREFIX,
            'guard node.source.count == prefix.count,\n              KimiMessage.sameSearchableWindow(prefix, node.source[...]) else {\n            return nil\n        }',
            '_ = prefix')


def d2_trace(files):
    replace(files, SEARCH,
            'guard let payload = node.payload(entryID: id) else { return nil }',
            'guard let payload = node.payload(entryID: id) else { return nil }\n                print("REVIEW_CONVERT query=\\(payload.query) id=\\(id)")')
    replace(files, SEARCH,
            'var adopted = previous\n                adopted.messages = entry.messages',
            'print("REVIEW_REUSE query=\\(query) id=\\(entry.id)")\n                var adopted = previous\n                adopted.messages = entry.messages')
    replace(files, TESTS,
            'assertOracleEqual(adopting.hits(in: advanced, query: "结论", running: false),',
            'print("REVIEW_D2_BEGIN")\n    assertOracleEqual(adopting.hits(in: advanced, query: "结论", running: false),')
    replace(files, TESTS,
            '"a within-instance advance over an ADOPTED shared node must reuse converted entries exactly")',
            '"a within-instance advance over an ADOPTED shared node must reuse converted entries exactly")\n    print("REVIEW_D2_END")')


def drop_converted(files):
    replace(files, SEARCH,
            'guard let payload = node.payload(entryID: id) else { return nil }',
            'guard let payload = node.payload(entryID: id), false else { return nil }')


try:
    control = run_case('control')
    if control.get('checks_exit') != 0:
        raise RuntimeError('candidate control did not pass')
    run_case('bypass-shared-hit', bypass)
    run_case('canonical-key', canonical)
    run_case('skip-verification', skip_verification)
    run_case('d2-trace', d2_trace)
    run_case('drop-converted-entry', drop_converted)
    run_case('restored-control')
finally:
    restore()
    receipt = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
               'restored': {p: (ROOT / p).read_text() == ORIGINAL[p] for p in FILES},
               'tracked_diff': subprocess.check_output(['git', 'diff', '--stat'], cwd=ROOT, text=True)}
    (ART / 'restore-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
