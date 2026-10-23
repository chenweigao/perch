#!/usr/bin/env python3
"""Start/reuse authenticated loopback services without tying their lifetime to Perch.

Kimi Web started here is recorded as Perch's own. Only that instance is ever
stopped: when the installed package or its saved launch environment changed and
no session is busy, it is replaced on the same port and keeps its token. A
service someone else started is reused as-is and never signalled.

Runs both on the Mac and, streamed over SSH, on remote hosts, so the Kimi path
stays compatible with Python 3.6.
"""
import argparse
import fcntl
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

VERSION = re.compile(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?')
ENV_NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*\Z')
# Shutdown closes every session and runs its SessionEnd hooks without an overall cap.
STOP_TIMEOUT = 90
READY_TIMEOUT = 15


def kimi_endpoint(port, token_path):
    # A response from another service or an authentication failure must never cause
    # us to replace it or rotate its credential.
    token = read_token(token_path)
    request = urllib.request.Request('http://127.0.0.1:%d/api/v1/models' % port,
                                     headers={'Authorization': 'Bearer ' + token})
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            body = json.load(response)
    except urllib.error.HTTPError:
        raise RuntimeError('The Kimi service on port %d rejected its saved credential.' % port) from None
    except urllib.error.URLError as error:
        if isinstance(error.reason, ConnectionRefusedError): return None
        raise RuntimeError('Could not contact the Kimi service on port %d.' % port) from None
    if body.get('code') != 0 or not isinstance(body.get('data', {}).get('items'), list):
        raise RuntimeError('Port %d did not return a Kimi model catalog.' % port)
    if not token: raise RuntimeError('The Kimi service has no saved credential.')
    return {'port': port, 'token': token}


def read_token(path):
    try: return path.read_text().strip()
    except OSError: return ''


def kimi_request(port, token, path, timeout=5):
    request = urllib.request.Request('http://127.0.0.1:%d%s' % (port, path),
                                     headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def kimi_meta(port, token):
    """`GET /api/v1/meta` data of the process answering on `port`, or {}."""
    try: body = kimi_request(port, token, '/api/v1/meta')
    except (OSError, ValueError): return {}
    data = body.get('data') if isinstance(body, dict) else None
    return data if isinstance(data, dict) else {}


def busy_sessions(port, token):
    """Sessions with a running turn, background task or compaction (`busy`) or an
    open approval or question. None when the catalog cannot be read completely:
    a service whose sessions are unknown is never reported idle."""
    count, before = 0, None
    for _ in range(1000):
        path = '/api/v1/sessions?page_size=100&include_archive=true'
        if before: path += '&before_id=' + urllib.parse.quote(before, safe='')
        try: body = kimi_request(port, token, path, timeout=10)
        except (OSError, ValueError): return None
        data = body.get('data') if isinstance(body, dict) and body.get('code') == 0 else None
        items = data.get('items') if isinstance(data, dict) else None
        if not isinstance(items, list): return None
        for item in items:
            if not isinstance(item, dict) or not isinstance(item.get('busy'), bool): return None
            if item['busy'] or item.get('main_turn_active') is True or item.get('pending_interaction') not in (None, 'none'):
                count += 1
        if not data.get('has_more'): return count
        before = items[-1].get('id') if items else None
        if not isinstance(before, str) or not before: return None
    return None


def parse_version(text):
    match = VERSION.search(text or '')
    return match.group(0) if match else None


def installed_version(binary, env):
    try:
        result = subprocess.run([binary, '--version'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, universal_newlines=True, timeout=30, env=env)
    except (OSError, subprocess.SubprocessError): return None
    return parse_version(result.stdout + result.stderr) if result.returncode == 0 else None


def alive(pid):
    """True while `pid` is a live process this user may signal."""
    if type(pid) is not int or pid <= 1: return False
    try:
        # A zombie still answers signal 0, so reap it first when it is our child.
        if os.waitpid(pid, os.WNOHANG)[0] == pid: return False
    except OSError: pass
    try: os.kill(pid, 0)
    except OSError: return False
    return True


def port_open(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(1)
        return probe.connect_ex(('127.0.0.1', port)) == 0


def instance_port(kimi_dir, pid):
    """The port a Kimi Web process registered. It differs from the requested port
    when that one was taken, because Kimi then binds the next free port."""
    for path in sorted((kimi_dir / 'server' / 'instances').glob('*.json')):
        try: entry = json.loads(path.read_text())
        except (OSError, ValueError): continue
        if isinstance(entry, dict) and entry.get('pid') == pid and type(entry.get('port')) is int:
            return entry['port']
    return None


def read_record(path):
    try: record = json.loads(path.read_text())
    except (OSError, ValueError): return None
    return record if isinstance(record, dict) else None


def write_record(path, record):
    staging = path.with_name(path.name + '.tmp')
    staging.write_text(json.dumps(record))
    os.replace(str(staging), str(path))


def remove_record(path):
    try: path.unlink()
    except FileNotFoundError: pass


def owned_service(record, token):
    """Meta of the instance this script started, while it is still that process.
    A reused pid or a restarted service reports another start time and is never
    treated as ours."""
    if not record or not token: return None
    pid, port, started = record.get('pid'), record.get('port'), record.get('startedAt')
    if not alive(pid) or type(port) is not int or not isinstance(started, str) or not started: return None
    meta = kimi_meta(port, token)
    return meta if meta.get('started_at') == started else None


def start_kimi(binary, port, home, env, kimi_dir, token_path, record_path, environment, replaced_for=None):
    with open(str(record_path.parent / 'kimi-web.log'), 'a') as log:
        process = subprocess.Popen([binary, 'web', '--host', '127.0.0.1', '--port', str(port), '--no-open'],
                                   cwd=str(home), env=env, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
    failure = None
    for _ in range(READY_TIMEOUT * 10):
        time.sleep(.1)
        actual = instance_port(kimi_dir, process.pid) or port
        try: endpoint = kimi_endpoint(actual, token_path)
        except RuntimeError as error:
            # The token file may appear only once the new service has booted.
            failure, endpoint = error, None
        if endpoint:
            meta = kimi_meta(actual, endpoint['token'])
            started = meta.get('started_at')
            if type(process.pid) is not int or not isinstance(started, str) or not started:
                return endpoint
            write_record(record_path, {'pid': process.pid, 'port': actual, 'startedAt': started,
                                       'version': parse_version(meta.get('server_version')),
                                       'environment': environment, 'replacedFor': replaced_for})
            endpoint['owned'] = True
            return endpoint
        if process.poll() is not None:
            raise RuntimeError('Kimi Web exited during startup. See ~/.local/state/perch/kimi-web.log.')
    raise failure or RuntimeError('The Kimi service did not become ready.')


def stop_kimi(pid, port, timeout):
    """SIGTERM, then SIGKILL after `timeout`. Kimi reclaims the session locks a
    killed process leaves behind, so the forced path does not strand a session."""
    try: os.kill(pid, signal.SIGTERM)
    except ProcessLookupError: return True
    except OSError: return False
    deadline = time.monotonic() + timeout
    while alive(pid):
        if time.monotonic() >= deadline:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: break
            except OSError: return False
            for _ in range(50):
                if not alive(pid): break
                time.sleep(.1)
            else: return False
            break
        time.sleep(.2)
    for _ in range(50):
        if not port_open(port): return True
        time.sleep(.1)
    return False


def refresh_owned(binary, home, env, kimi_dir, token_path, record_path, record, service, token, environment, stop_timeout):
    port = record['port']
    endpoint = {'port': port, 'token': token, 'owned': True}
    running = parse_version(service.get('server_version'))
    installed = installed_version(binary, env)
    if running: endpoint['runningVersion'] = running
    if installed: endpoint['installedVersion'] = installed
    if installed and running and installed != running:
        endpoint['restartReason'] = 'update'
        # A restart already started this package and the service still reports another
        # version (a staged native update, another PATH entry): report it, do not loop.
        if record.get('replacedFor') == installed:
            endpoint['restartPending'] = -1
            return endpoint
    elif record.get('environment') != environment:
        endpoint['restartReason'] = 'settings'
    else:
        return endpoint
    busy = busy_sessions(port, token)
    if busy is None or busy:
        endpoint['restartPending'] = -1 if busy is None else busy
        return endpoint
    if not stop_kimi(record['pid'], port, stop_timeout):
        endpoint['restartPending'] = -1
        return endpoint
    remove_record(record_path)
    replaced_for = installed if endpoint['restartReason'] == 'update' else record.get('replacedFor')
    started = start_kimi(binary, port, home, env, kimi_dir, token_path, record_path, environment, replaced_for)
    started['replaced'] = True
    started['restartReason'] = endpoint['restartReason']
    return started


def ensure_kimi(binary, port, home, token_path=None, environment=None, stop_timeout=STOP_TIMEOUT):
    environment = dict(environment or {})
    env = dict(os.environ)
    env.update(environment)
    kimi_dir = pathlib.Path(env.get('KIMI_CODE_HOME') or str(home / '.kimi-code')).expanduser()
    token_path = pathlib.Path(token_path).expanduser() if token_path else kimi_dir / 'server.token'
    state = home / '.local/state/perch'
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    record_path = state / ('kimi-web-%d.json' % port)
    with open(str(state / ('kimi-web-%d.lock' % port)), 'w') as lock:
        # Two clients checking at once must not both replace the service.
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = read_record(record_path)
        token = read_token(token_path)
        service = owned_service(record, token)
        if service is not None:
            return refresh_owned(binary, home, env, kimi_dir, token_path, record_path, record, service,
                                 token, environment, stop_timeout)
        if record is not None: remove_record(record_path)
        endpoint = kimi_endpoint(port, token_path)
        if endpoint: return endpoint
        return start_kimi(binary, port, home, env, kimi_dir, token_path, record_path, environment)


def parse_environment(entries):
    environment = {}
    for entry in entries or []:
        name, separator, value = entry.partition('=')
        if not separator or not ENV_NAME.match(name) or '\0' in value or '\n' in value:
            raise RuntimeError('Invalid Kimi Web environment entry: %s' % name)
        environment[name] = value
    return environment


def resolve_kimi():
    """The executable the setup probe finds: the SSH PATH first, then npm's global prefix."""
    found = shutil.which('kimi')
    if found: return os.path.abspath(found)
    try:
        prefix = subprocess.run(['npm', 'prefix', '-g'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError): prefix = ''
    candidate = os.path.join(prefix, 'bin', 'kimi') if prefix else ''
    if candidate and os.access(candidate, os.X_OK): return candidate
    raise RuntimeError('Kimi was not found in the SSH PATH or the npm global prefix. Run the setup check again.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--agent', choices=['kimi', 'codex'], required=True)
    parser.add_argument('--binary')
    parser.add_argument('--port', type=int, default=58627)
    parser.add_argument('--token-path')
    parser.add_argument('--env', action='append', default=[])
    parser.add_argument('--stop-timeout', type=float, default=STOP_TIMEOUT)
    args = parser.parse_args()
    os.umask(0o077)
    binary = args.binary or (resolve_kimi() if args.agent == 'kimi' else None)
    if not binary or not os.path.isabs(binary) or not os.access(binary, os.X_OK):
        raise RuntimeError('The selected agent executable is unavailable.')
    if not 1 <= args.port <= 65535: raise RuntimeError('The Kimi port must be 1-65535.')
    os.environ['PATH'] = str(pathlib.Path(binary).parent) + os.pathsep + os.environ.get('PATH', '')
    if args.agent == 'kimi':
        endpoint = ensure_kimi(binary, args.port, pathlib.Path.home(), args.token_path,
                               parse_environment(args.env), args.stop_timeout)
        print(json.dumps(endpoint))
    else:
        os.environ['AWB_NATIVE_ROOT'] = str(pathlib.Path.home() / '.local/share/perch/local-native')
        os.environ['PERCH_LOCAL_CODEX'] = binary
        os.execv(sys.executable, [sys.executable, str(pathlib.Path(__file__).with_name('native-agent-service.py')), '--ensure'])


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
