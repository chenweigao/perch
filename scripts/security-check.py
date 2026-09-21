#!/usr/bin/env python3
"""Local/CI secret checks. Never print candidate credential values."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
spec = importlib.util.spec_from_file_location('publication', Path(__file__).with_name('check-public-source.py'))
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])


def common_dir():
    return (ROOT / git('rev-parse', '--git-common-dir').decode().strip()).resolve()


def scan_source(staged, revisions):
    count = 0
    seen = set()
    if staged:
        trees = [git('ls-files', '--stage', '-z')]
    else:
        commits = git('rev-list', *revisions, '--').decode().splitlines()
        trees = (git('ls-tree', '-rz', commit) for commit in commits)
        identities = git('log', '--format=%ae%n%ce', *revisions, '--')
        # Public GitHub noreply identities are deliberate, not private addresses.
        identities = re.sub(rb'(?m)^(?:[A-Za-z0-9+_.-]+@users\.noreply\.github\.com|noreply@github\.com)$', b'', identities)
        count += publication.findings('commit-identities', identities)
    for tree in trees:
        for entry in tree.split(b'\0'):
            if not entry:
                continue
            metadata, raw_name = entry.split(b'\t', 1)
            fields = metadata.split()
            mode, oid = (fields[0], fields[1]) if staged else (fields[0], fields[2])
            name = raw_name.decode()
            path = Path(name)
            if path.name == '.env' or (path.name.startswith('.env.') and path.name != '.env.example') or path.suffix in ('.pem', '.key', '.p12', '.pfx') or '.session-export' in path.parts:
                print(f'{name}: private file type')
                count += 1
            if mode == b'160000' or oid in seen:
                continue
            seen.add(oid)
            count += publication.findings(name, git('cat-file', 'blob', oid.decode()))
    return count == 0


def scan(staged, revisions):
    binary = common_dir() / 'perch-tools/gitleaks'
    if not binary.is_file():
        print('Secret checks unavailable. Run: python3 scripts/setup-security.py', file=sys.stderr)
        return False
    source_ok = scan_source(staged, revisions)
    with tempfile.TemporaryDirectory(prefix='perch-secrets-') as directory:
        temp = Path(directory)
        (temp / 'config.toml').write_text('[extend]\nuseDefault = true\n')
        (temp / 'ignore').write_text('')
        command = [str(binary), 'git', str(ROOT), '--redact=100', '--no-banner', '--no-color',
                   '--ignore-gitleaks-allow', '--config', str(temp / 'config.toml'),
                   '--gitleaks-ignore-path', str(temp / 'ignore'),
                   '--report-format', 'json', '--report-path', str(temp / 'report.json')]
        command += ['--pre-commit', '--staged'] if staged else ['--log-opts=' + ' '.join(revisions)]
        result = subprocess.run(command, capture_output=True)
        if result.returncode:
            print(f'Gitleaks blocked this operation (exit {result.returncode}). Credential values are hidden.', file=sys.stderr)
            if (temp / 'report.json').exists():
                for item in json.loads((temp / 'report.json').read_text()):
                    print(f"{item['File']}:{item['StartLine']}: {item['RuleID']}", file=sys.stderr)
            return False
    if source_ok:
        print('Secret and publication checks passed.')
    return source_ok


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['staged', 'history', 'hook'])
    parser.add_argument('arguments', nargs='*')
    args = parser.parse_args()
    if args.mode == 'staged':
        return 0 if scan(True, []) else 1
    if args.mode == 'history':
        # Resolve to object IDs before passing revisions to Gitleaks' option string.
        revisions = [git('rev-parse', '--verify', ref + '^{commit}').decode().strip() for ref in (args.arguments or ['HEAD'])]
        return 0 if scan(False, revisions) else 1
    hook, *hook_args = args.arguments
    incoming = sys.stdin.buffer.read() if hook == 'pre-push' else b''
    previous = git('config', '--get', 'perch.previousHooksPath').decode().strip()
    original = Path(previous) / hook
    has_original = original.is_file() and os.access(original, os.X_OK)
    if hook == 'pre-commit':
        if has_original:
            result = subprocess.run([str(original), *hook_args])
            if result.returncode:
                return result.returncode
        return 0 if scan(True, []) else 1
    elif hook == 'pre-push':
        tips = {line.split()[1].decode() for line in incoming.splitlines() if line and set(line.split()[1]) != {ord('0')}}
        # Scan every commit reachable from pushed tips, including secrets later deleted.
        passed = not tips or scan(False, sorted(tips))
    else:
        parser.error('Only pre-commit and pre-push hooks are supported')
    if not passed:
        return 1
    if has_original:
        return subprocess.run([str(original), *hook_args], input=incoming).returncode
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError):
        print('Secret checks could not complete; operation blocked. Check Git state and scanner installation.', file=sys.stderr)
        sys.exit(1)
