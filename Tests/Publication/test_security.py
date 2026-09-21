import importlib.util
import os
from pathlib import Path
import secrets
import shutil
import string
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMMON = (ROOT / subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--git-common-dir'], text=True).strip()).resolve()
SCANNER = COMMON / 'perch-tools/gitleaks'
spec = importlib.util.spec_from_file_location('setup_security', ROOT / 'scripts/setup-security.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


@unittest.skipUnless(SCANNER.exists(), 'Install the pinned scanner with scripts/setup-security.py --tools-only')
class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.test')
        self.old = self.root / '.git/old-hooks'
        self.old.mkdir()
        self.git('config', 'core.hooksPath', str(self.old))
        (self.root / '.git/perch-tools').mkdir()
        self.binary = self.root / '.git/perch-tools/gitleaks'
        self.binary.symlink_to(SCANNER)
        (self.root / 'scripts').mkdir()
        for name in ('security-check.py', 'check-public-source.py'):
            shutil.copyfile(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        (self.root / 'README.md').write_text('synthetic fixture\n')
        self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], stderr=subprocess.DEVNULL)

    def commit(self):
        self.git('add', '.')
        # Intentionally seeded leaks must only enter isolated temporary history.
        self.git('-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')

    def check(self, *args, incoming=None):
        return subprocess.run(['python3', str(self.root / 'scripts/security-check.py'), *args],
                              cwd=self.root, input=incoming, capture_output=True)

    def token(self):
        return 'ghp_' + ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36))

    def install_hooks(self):
        cwd = Path.cwd()
        try:
            os.chdir(self.root)
            setup.install_hooks(self.root, self.root / '.git')
        finally:
            os.chdir(cwd)

    def original_hook(self, name, contents):
        path = self.old / name
        path.write_text('#!/bin/sh\n' + contents)
        path.chmod(0o755)
        return path

    def test_staged_secret_blocks_even_when_worktree_is_clean(self):
        value = self.token()
        path = self.root / 'sample.txt'
        path.write_text(value)
        self.git('add', 'sample.txt')
        path.write_text('clean working copy')
        result = self.check('staged')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Gitleaks blocked', result.stderr)
        self.assertNotIn(value.encode(), result.stdout + result.stderr)

    def test_unstaged_secret_does_not_contaminate_staged_scan(self):
        path = self.root / 'sample.txt'
        path.write_text('safe staged change')
        self.git('add', 'sample.txt')
        path.write_text(self.token())
        self.assertEqual(self.check('staged').returncode, 0)

    def test_history_catches_secret_removed_before_tip(self):
        value = self.token()
        path = self.root / 'sample.txt'
        path.write_text(value)
        self.commit()
        path.unlink()
        self.commit()
        result = self.check('history', 'HEAD')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(value.encode(), result.stdout + result.stderr)

    def test_export_ignore_does_not_hide_tracked_private_data(self):
        (self.root / '.gitattributes').write_text('internal export-ignore\n')
        (self.root / 'internal').mkdir()
        (self.root / 'internal/note.txt').write_text('/Users/' + 'private-fixture/project')
        self.git('add', '.')
        self.assertNotEqual(self.check('staged').returncode, 0)

    def test_history_checks_identity_without_rejecting_github_noreply(self):
        self.git('config', 'user.email', 'noreply@' + 'github.com')
        (self.root / 'README.md').write_text('safe GitHub identity')
        self.commit()
        self.assertEqual(self.check('history', 'HEAD').returncode, 0)
        private = 'fixture@' + 'company.test'
        self.git('config', 'user.email', private)
        (self.root / 'README.md').write_text('identity requires review')
        self.commit()
        result = self.check('history', 'HEAD')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(private.encode(), result.stdout + result.stderr)

    def test_missing_or_broken_scanner_blocks(self):
        self.binary.unlink()
        self.assertNotEqual(self.check('staged').returncode, 0)
        self.binary.write_text('#!/bin/sh\nexit 2\n')
        self.binary.chmod(0o755)
        self.assertNotEqual(self.check('staged').returncode, 0)

    def test_existing_hooks_and_push_stdin_are_preserved(self):
        old = self.original_hook('pre-push', 'printf "%s\\n" "$@" > .git/args\ncat > .git/input\nexit 7\n')
        original = old.read_bytes()
        self.original_hook('post-commit', 'exit 0\n')
        self.install_hooks()
        self.install_hooks()
        self.assertEqual(old.read_bytes(), original)
        self.assertEqual(self.git('config', 'perch.previousHooksPath').decode().strip(), str(self.old.resolve()))
        self.assertTrue((self.root / '.git/perch-hooks/post-commit').is_symlink())
        tip = self.git('rev-parse', 'HEAD').strip()
        incoming = b'refs/heads/main ' + tip + b' refs/heads/main ' + b'0' * 40 + b'\n'
        result = self.check('hook', 'pre-push', 'origin', 'fixture.example', incoming=incoming)
        self.assertEqual(result.returncode, 7)
        self.assertEqual((self.root / '.git/input').read_bytes(), incoming)
        self.assertEqual((self.root / '.git/args').read_text(), 'origin\nfixture.example\n')

    def test_actual_push_blocks_a_secret_deleted_in_later_commit(self):
        value = self.token()
        path = self.root / 'sample.txt'
        path.write_text(value)
        self.commit()
        path.unlink()
        self.commit()
        receiver = self.root / '.git/receiver.git'
        self.git('init', '--bare', '-q', str(receiver))
        self.install_hooks()
        result = subprocess.run(['git', 'push', str(receiver), 'HEAD:refs/heads/main'], cwd=self.root, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(value.encode(), result.stdout + result.stderr)
        refs = subprocess.check_output(['git', '--git-dir=' + str(receiver), 'for-each-ref'])
        self.assertEqual(refs, b'')

    def test_original_precommit_changes_are_scanned(self):
        self.original_hook('pre-commit', 'printf "fixture" > .env\ngit add -f .env\n')
        self.install_hooks()
        result = self.check('hook', 'pre-commit')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'private file type', result.stdout)

    def test_actual_commit_hook_blocks_seeded_secret(self):
        self.install_hooks()
        value = self.token()
        (self.root / 'sample.txt').write_text(value)
        self.git('add', 'sample.txt')
        result = subprocess.run(['git', '-c', 'commit.gpgsign=false', 'commit', '-m', 'blocked fixture'], cwd=self.root, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git('rev-list', '--count', 'HEAD').strip(), b'1')
        self.assertNotIn(value.encode(), result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
