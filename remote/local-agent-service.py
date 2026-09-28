#!/usr/bin/env python3
"""Start/reuse authenticated loopback services without tying their lifetime to Perch."""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request


def kimi_endpoint(port, token_path):
    # A response from another service or an authentication failure must never cause
    # us to replace it or rotate its credential.
    token = token_path.read_text().strip() if token_path.exists() else ''
    request = urllib.request.Request(f'http://127.0.0.1:{port}/api/v1/models',
                                    headers={'Authorization': 'Bearer ' + token})
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            body = json.load(response)
    except urllib.error.HTTPError:
        raise RuntimeError('The local Kimi service rejected its saved credential.') from None
    except urllib.error.URLError as error:
        if isinstance(error.reason, ConnectionRefusedError): return None
        raise RuntimeError('Could not contact the local Kimi service.') from None
    if body.get('code') != 0 or not isinstance(body.get('data', {}).get('items'), list):
        raise RuntimeError('The local port did not return a Kimi model catalog.')
    if not token: raise RuntimeError('The local Kimi service has no saved credential.')
    return {'port': port, 'token': token}


def ensure_kimi(binary, port, home):
    token_path = pathlib.Path(os.environ.get('KIMI_CODE_HOME', str(home / '.kimi-code'))) / 'server.token'
    endpoint = kimi_endpoint(port, token_path)
    if endpoint: return endpoint
    state = home / '.local/state/perch'
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(state / 'kimi-web.log', 'a') as log:
        subprocess.Popen([binary, 'web', '--host', '127.0.0.1', '--port', str(port), '--no-open'],
                         cwd=home, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                         start_new_session=True)
    for _ in range(100):
        time.sleep(.1)
        endpoint = kimi_endpoint(port, token_path)
        if endpoint: return endpoint
    raise RuntimeError('The local Kimi service did not become ready.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--agent', choices=['kimi', 'codex'], required=True)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--port', type=int, default=58627)
    args = parser.parse_args()
    os.umask(0o077)
    if not os.path.isabs(args.binary) or not os.access(args.binary, os.X_OK):
        raise RuntimeError('The selected agent executable is unavailable.')
    os.environ['PATH'] = str(pathlib.Path(args.binary).parent) + os.pathsep + os.environ.get('PATH', '')
    if args.agent == 'kimi':
        endpoint = ensure_kimi(args.binary, args.port, pathlib.Path.home())
        print(json.dumps(endpoint))
    else:
        os.environ['AWB_NATIVE_ROOT'] = str(pathlib.Path.home() / '.local/share/perch/local-native')
        os.environ['PERCH_LOCAL_CODEX'] = args.binary
        os.execv(sys.executable, [sys.executable, str(pathlib.Path(__file__).with_name('native-agent-service.py')), '--ensure'])


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
