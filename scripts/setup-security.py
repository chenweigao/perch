#!/usr/bin/env python3
"""Install pinned Gitleaks and repository-local hooks, preserving existing hooks."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile

VERSION = '8.30.1'
CHECKSUMS = {
    'darwin_arm64': 'b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5',
    'darwin_x64': 'dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709',
    'linux_arm64': 'e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080',
    'linux_x64': '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb',
}


def install_hooks(root, common):
    root, common = root.resolve(), common.resolve()
    hooks = common / 'perch-hooks'
    current = subprocess.run(['git', 'config', '--get', 'core.hooksPath'], capture_output=True, text=True)
    previous = (root / current.stdout.strip()).resolve() if current.returncode == 0 else common / 'hooks'
    if hooks.exists() and not (hooks / '.perch-managed').exists():
        raise RuntimeError('Refusing to overwrite an unmanaged hooks directory')
    hooks.mkdir(exist_ok=True)
    (hooks / '.perch-managed').touch()
    if previous != hooks:
        subprocess.run(['git', 'config', '--local', 'perch.previousHooksPath', str(previous)], check=True)
    else:
        previous = Path(subprocess.check_output(['git', 'config', '--get', 'perch.previousHooksPath'], text=True).strip())
    # Preserve other existing hooks as well as the two hooks we wrap.
    if previous.is_dir():
        for original in previous.iterdir():
            if original.is_file() and os.access(original, os.X_OK) and original.name not in ('pre-commit', 'pre-push'):
                target = hooks / original.name
                if target.is_symlink():
                    target.unlink()
                target.symlink_to(original)
    for name in ('pre-commit', 'pre-push'):
        script = hooks / name
        script.write_text('#!/bin/sh\nset -eu\nroot="$(git rev-parse --show-toplevel)"\nexec python3 "$root/scripts/security-check.py" hook ' + name + ' "$@"\n')
        script.chmod(0o755)
    subprocess.run(['git', 'config', '--local', 'core.hooksPath', str(hooks)], check=True)
    print('Installed repository-local checks; existing hooks remain chained. Global Git configuration is unchanged.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-only', action='store_true', help='Install only the scanner (for CI)')
    args = parser.parse_args()
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
    common = (root / subprocess.check_output(['git', 'rev-parse', '--git-common-dir'], text=True).strip()).resolve()
    architecture = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'x64'}[platform.machine()]
    target = platform.system().lower() + '_' + architecture
    asset = f'gitleaks_{VERSION}_{target}.tar.gz'
    tools = common / 'perch-tools'
    tools.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='perch-tools-') as directory:
        archive = Path(directory) / asset
        subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--output', str(archive),
                        f'https://github.com/gitleaks/gitleaks/releases/download/v{VERSION}/{asset}'], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != CHECKSUMS[target]:
            raise RuntimeError('Gitleaks download checksum mismatch')
        with tarfile.open(archive) as contents:
            member = contents.getmember('gitleaks')
            if not member.isfile():
                raise RuntimeError('Expected a regular Gitleaks executable')
            (tools / 'gitleaks').write_bytes(contents.extractfile(member).read())
            (tools / 'gitleaks').chmod(0o755)
    print(f'Installed Gitleaks {VERSION}; pinned archive checksum verified.')
    if not args.tools_only:
        install_hooks(root, common)


if __name__ == '__main__':
    main()
