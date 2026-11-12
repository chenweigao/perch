import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def patch(tag):
    return ('--- a/Sources/Font.swift\n+++ b/Sources/Font.swift\n@@ -1 +1 @@\n'
            '-let bundle = "module"\n+let bundle = "' + tag + '"\n')


class MathBuildPatchTests(unittest.TestCase):
    def prepare(self, directory):
        root = Path(directory)
        (root / 'scripts').mkdir()
        build = ROOT / 'scripts/build-math-performance-preview.sh'
        shutil.copy2(build, root / 'scripts')
        (root / 'Tests/MathPerformancePreview').mkdir(parents=True)
        shutil.copy2(ROOT / 'Tests/MathPerformancePreview/App.swift', root / 'Tests/MathPerformancePreview')
        (root / 'Sources/WorkbenchCore').mkdir(parents=True)
        (root / 'Sources/WorkbenchCore/ReplyMath.swift').write_text('import Foundation\n')
        (root / 'Sources/AgentWorkbench').mkdir()
        for name in re.search(r'for name in (.*?); do', build.read_text()).group(1).split():
            (root / 'Sources/AgentWorkbench' / (name + '.swift')).write_text('import Foundation\n')
        shutil.copy2(ROOT / 'Package.resolved', root)
        (root / 'patches').mkdir()
        (root / 'patches/swiftmath-app-resources.patch').write_text(patch('app-v1'))
        self.git(root, 'init', '-q')
        self.git(root, 'config', 'user.name', 'Math Fixture')
        self.git(root, 'config', 'user.email', 'fixture@example.test')
        self.git(root, 'add', '.')
        self.git(root, 'commit', '-qm', 'fixture v1')
        old = self.git(root, 'rev-parse', 'HEAD').strip()
        dep = root / '.build/checkouts/SwiftMath/Sources'
        dep.mkdir(parents=True)
        (dep / 'Font.swift').write_text('let bundle = "app-v1"\n')
        self.git(dep.parent, 'init', '-q')
        for path in ['swift-markdown/Sources/CAtomic/include', 'swift-cmark/src/include', 'swift-cmark/extensions/include']:
            (root / '.build/checkouts' / path).mkdir(parents=True)
        binary = root / 'bin'
        (binary / 'Modules').mkdir(parents=True)
        for target in ['WorkbenchCore', 'SwiftMath']:
            (binary / 'Modules' / (target + '.swiftmodule')).write_bytes(b'module')
        for target in ['WorkbenchCore', 'Markdown', 'CAtomic', 'cmark_gfm', 'cmark_gfm_extensions', 'SwiftMath']:
            (binary / (target + '.build')).mkdir()
            (binary / (target + '.build/fixture.o')).write_bytes(b'')
        stubs = root / 'stubs'
        stubs.mkdir()
        swift = stubs / 'swift'
        swift.write_text('#!' + sys.executable + '\n' + '''import os, pathlib, subprocess, sys
args = sys.argv[1:]
with open(os.environ['MATH_CALLS'], 'a') as out: out.write(' '.join(args)+'\\n')
if '--version' in args: print('fixture toolchain')
elif '--show-bin-path' in args: print(os.environ['MATH_TEST_BIN'])
elif '--package-path' in args:
    snapshot = pathlib.Path(args[args.index('--package-path')+1])
    dep = snapshot / '.build/checkouts/SwiftMath'
    if args[0] == 'package':
        (dep/'Sources').mkdir(parents=True, exist_ok=True)
        (dep/'Sources/Font.swift').write_text('let bundle = "module"\\n')
        subprocess.run(['git','init','-q',str(dep)], check=True)
    elif '--target' in args:
        expected = os.environ['MATH_EXPECTED_TAG']
        if (dep/'Sources/Font.swift').read_text() != 'let bundle = "'+expected+'"\\n': sys.exit(93)
''')
        swift.chmod(0o755)
        swiftc = stubs / 'swiftc'
        swiftc.write_text('#!/bin/sh\nexit 97\n')
        swiftc.chmod(0o755)
        env = dict(os.environ, PATH=str(stubs)+os.pathsep+os.environ['PATH'],
                   MATH_CALLS=str(root/'calls.log'), MATH_TEST_BIN=str(binary), MATH_EXPECTED_TAG='app-v1')
        return root, env, old

    def git(self, root, *args):
        return subprocess.check_output(['git', *args], cwd=root, text=True, stderr=subprocess.DEVNULL)

    def build(self, root, env, variant, revision='HEAD'):
        result = subprocess.run(['bash', 'scripts/build-math-performance-preview.sh', variant, revision],
                                cwd=root, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 97, result.stdout + result.stderr)
        return json.loads((root / ('build/Math Performance '+variant+'.app/Contents/Resources/build.json')).read_text())

    def test_fresh_build_patches_before_compile_and_matches_reused_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root, env, _ = self.prepare(directory)
            base = self.build(root, env, 'baseline')
            calls = (root/'calls.log').read_text()
            self.assertIn('package --package-path', calls)
            self.assertLess(calls.index('package --package-path'), calls.index('--target SwiftMath'))
            (root/'calls.log').write_text('')
            candidate = self.build(root, dict(env, PERCH_REUSE_PREBUILT='1'), 'candidate')
            calls = (root/'calls.log').read_text()
            self.assertNotIn('--target', calls)
            self.assertNotIn('package --package-path', calls)
            self.assertEqual(base['source_input_sha256'], candidate['source_input_sha256'])
            self.assertEqual(base['swiftmath_patch_sha256'], hashlib.sha256(patch('app-v1').encode()).hexdigest())

    def test_unpatched_prebuilt_dependency_forces_fresh_patched_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root, env, _ = self.prepare(directory)
            (root/'.build/checkouts/SwiftMath/Sources/Font.swift').write_text('let bundle = "module"\n')
            self.build(root, dict(env, PERCH_REUSE_PREBUILT='1'), 'candidate')
            self.assertIn('--target SwiftMath', (root/'calls.log').read_text())

    def test_patch_revision_changes_identity_and_blocks_old_prebuilt_reuse(self):
        with tempfile.TemporaryDirectory() as directory:
            root, env, old = self.prepare(directory)
            baseline = self.build(root, env, 'baseline', old)
            (root/'patches/swiftmath-app-resources.patch').write_text(patch('app-v2'))
            self.git(root, 'add', 'patches')
            self.git(root, 'commit', '-qm', 'fixture v2')
            (root/'calls.log').write_text('')
            candidate = self.build(root, dict(env, PERCH_REUSE_PREBUILT='1', MATH_EXPECTED_TAG='app-v2'), 'candidate')
            self.assertIn('--target SwiftMath', (root/'calls.log').read_text())
            self.assertNotEqual(baseline['source_input_sha256'], candidate['source_input_sha256'])
            self.assertNotEqual(baseline['swiftmath_patch_sha256'], candidate['swiftmath_patch_sha256'])


if __name__ == '__main__':
    unittest.main()
