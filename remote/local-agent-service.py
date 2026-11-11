#!/usr/bin/env python3
"""Start or reuse the local native agent bridge without tying its lifetime to Perch."""
import argparse
import os
import pathlib
import shutil
import subprocess
import sys


def resolve_kimi():
    """The executable the setup probe finds: PATH first, then npm's global prefix."""
    found = shutil.which('kimi')
    if found:
        return os.path.abspath(found)
    try:
        prefix = subprocess.run(
            ['npm', 'prefix', '-g'],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            universal_newlines=True,
            timeout=30,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        prefix = ''
    candidate = os.path.join(prefix, 'bin', 'kimi') if prefix else ''
    if candidate and os.access(candidate, os.X_OK):
        return candidate
    raise RuntimeError('Kimi was not found in PATH or the npm global prefix. Run the setup check again.')


def validate_binary(binary):
    if not binary or not os.path.isabs(binary) or not os.access(binary, os.X_OK):
        raise RuntimeError('The selected agent executable is unavailable.')
    return os.path.abspath(binary)


def build_bridge_environment(kimi_binary=None, codex_binary=None, base_env=None, home=None):
    env = dict(os.environ if base_env is None else base_env)
    prefixes = []
    if kimi_binary:
        kimi_path = validate_binary(kimi_binary)
        env['PERCH_LOCAL_KIMI'] = kimi_path
        prefixes.append(str(pathlib.Path(kimi_path).parent))
    else:
        env.pop('PERCH_LOCAL_KIMI', None)
    if codex_binary:
        codex_path = validate_binary(codex_binary)
        env['PERCH_LOCAL_CODEX'] = codex_path
        prefixes.append(str(pathlib.Path(codex_path).parent))
    else:
        env.pop('PERCH_LOCAL_CODEX', None)
    if not prefixes:
        raise RuntimeError('Select at least one local agent executable.')
    seen = []
    for folder in prefixes + env.get('PATH', '').split(os.pathsep):
        if folder and folder not in seen:
            seen.append(folder)
    env['PATH'] = os.pathsep.join(seen)
    root_home = pathlib.Path.home() if home is None else pathlib.Path(home)
    env['AWB_NATIVE_ROOT'] = str(root_home / '.local/share/perch/local-native')
    return env


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--agent', choices=['kimi', 'codex'])
    parser.add_argument('--binary')
    parser.add_argument('--kimi-binary')
    parser.add_argument('--codex-binary')
    args = parser.parse_args()
    os.umask(0o077)
    kimi_binary = args.kimi_binary
    codex_binary = args.codex_binary
    if args.agent == 'kimi':
        kimi_binary = args.binary or kimi_binary or resolve_kimi()
    elif args.agent == 'codex':
        codex_binary = args.binary or codex_binary
    env = build_bridge_environment(kimi_binary=kimi_binary, codex_binary=codex_binary)
    os.environ.clear()
    os.environ.update(env)
    service = pathlib.Path(__file__).with_name('native-agent-service.py')
    os.execv(sys.executable, [sys.executable, str(service), '--ensure'])


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
