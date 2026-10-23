import base64
import importlib.util
import io
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).with_name('local-agent-service.py')
spec = importlib.util.spec_from_file_location('local_service', SCRIPT)
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)

# Same loader the Mac uses to stream this script to a remote host (RemoteSetup.kimiEnsureCommand).
LOADER = 'import base64,sys;exec(compile(base64.b64decode(sys.argv.pop(1)),"perch-kimi-web","exec"))'


def owned_home(root, record):
    home = pathlib.Path(root)
    token = home / '.kimi-code/server.token'
    token.parent.mkdir(parents=True)
    token.write_text('fixture-token')
    state = home / '.local/state/perch'
    state.mkdir(parents=True)
    (state / 'kimi-web-58627.json').write_text(json.dumps(record))
    return home, state / 'kimi-web-58627.json'


RECORD = {'pid': 4242, 'port': 58627, 'startedAt': '2026-10-22T07:05:48.846Z', 'version': '2.3.0',
          'environment': {}, 'replacedFor': None}
META = {'started_at': '2026-10-22T07:05:48.846Z', 'server_version': '2.3.0'}


class LocalServiceTests(unittest.TestCase):
    def test_existing_service_is_reused_without_launching_or_rotating_token(self):
        with tempfile.TemporaryDirectory() as root:
            home = pathlib.Path(root); token = home/'.kimi-code/server.token'
            token.parent.mkdir(); token.write_text('fixture-token')
            with patch.dict(service.os.environ, {}, clear=True), patch.object(service.urllib.request, 'urlopen', return_value=io.BytesIO(b'{"code":0,"data":{"items":[]}}')), patch.object(service.subprocess, 'Popen') as launch:
                self.assertEqual(service.ensure_kimi('/fixture/kimi', 58627, home), {'port':58627,'token':'fixture-token'})
                launch.assert_not_called()
                self.assertEqual(token.read_text(), 'fixture-token')

    def test_auth_failure_does_not_launch_or_replace_service(self):
        error = urllib.error.HTTPError('http://127.0.0.1',401,'Unauthorized',{},None)
        with tempfile.TemporaryDirectory() as root, patch.object(service.urllib.request,'urlopen',side_effect=error), patch.object(service.subprocess,'Popen') as launch:
            with self.assertRaisesRegex(RuntimeError, 'credential'): service.ensure_kimi('/fixture/kimi', 58627, pathlib.Path(root))
            launch.assert_not_called()

    def test_unrelated_loopback_service_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as root, patch.object(service.urllib.request,'urlopen',return_value=io.BytesIO(b'{"ok":true}')), patch.object(service.subprocess,'Popen') as launch:
            with self.assertRaisesRegex(RuntimeError, 'catalog'): service.ensure_kimi('/fixture/kimi', 58627, pathlib.Path(root))
            launch.assert_not_called()

    def test_fresh_service_is_detached_authenticated_and_recorded(self):
        with tempfile.TemporaryDirectory() as root, patch.object(service, 'kimi_endpoint',side_effect=[None, {'port':58627,'token':'test'}]), patch.object(service, 'kimi_meta', return_value=META), patch.object(service.subprocess,'Popen') as launch, patch.object(service.time,'sleep'):
            launch.return_value.pid = 4242
            launch.return_value.poll.return_value = None
            endpoint = service.ensure_kimi('/path with spaces/kimi', 58627, pathlib.Path(root), environment={'KIMI_CODE_INFINITE_RETRY': 'true'})
            args, kwargs = launch.call_args
            self.assertEqual(args[0], ['/path with spaces/kimi','web','--host','127.0.0.1','--port','58627','--no-open'])
            self.assertTrue(kwargs['start_new_session'])
            self.assertEqual(kwargs['stdin'], service.subprocess.DEVNULL)
            self.assertEqual(kwargs['env']['KIMI_CODE_INFINITE_RETRY'], 'true')
            self.assertNotIn('--dangerous-bypass-auth', args[0])
            self.assertEqual(endpoint, {'port':58627,'token':'test','owned':True})
            record = json.loads((pathlib.Path(root)/'.local/state/perch/kimi-web-58627.json').read_text())
            self.assertEqual(record['pid'], 4242)
            self.assertEqual(record['startedAt'], META['started_at'])
            self.assertEqual(record['environment'], {'KIMI_CODE_INFINITE_RETRY': 'true'})

    def test_timeout_is_not_treated_as_missing_service(self):
        with tempfile.TemporaryDirectory() as root, patch.object(service.urllib.request,'urlopen',side_effect=urllib.error.URLError(TimeoutError())), patch.object(service.subprocess,'Popen') as launch:
            with self.assertRaises(RuntimeError): service.ensure_kimi('/fixture/kimi',58627,pathlib.Path(root))
            launch.assert_not_called()

    def test_start_uses_the_port_kimi_registered(self):
        # A taken port makes Kimi bind the next one; the instance registry names it.
        with tempfile.TemporaryDirectory() as root:
            home = pathlib.Path(root)
            instances = home/'.kimi-code/server/instances'
            instances.mkdir(parents=True)
            (instances/'a.json').write_text(json.dumps({'pid': 4242, 'port': 58628, 'host': '127.0.0.1'}))
            def endpoint(port, token_path):
                return {'port': port, 'token': 'test'} if port == 58628 else None
            with patch.object(service, 'kimi_endpoint', side_effect=endpoint), patch.object(service, 'kimi_meta', return_value=META), patch.object(service.subprocess, 'Popen') as launch, patch.object(service.time, 'sleep'):
                launch.return_value.pid = 4242
                launch.return_value.poll.return_value = None
                self.assertEqual(service.ensure_kimi('/fixture/kimi', 58627, home), {'port': 58628, 'token': 'test', 'owned': True})
            self.assertEqual(json.loads((home/'.local/state/perch/kimi-web-58627.json').read_text())['port'], 58628)

    def test_start_reports_an_exited_service(self):
        with tempfile.TemporaryDirectory() as root, patch.object(service, 'kimi_endpoint', return_value=None), patch.object(service.subprocess, 'Popen') as launch, patch.object(service.time, 'sleep'):
            launch.return_value.pid = 4242
            launch.return_value.poll.return_value = 1
            with self.assertRaisesRegex(RuntimeError, 'exited'): service.ensure_kimi('/fixture/kimi', 58627, pathlib.Path(root))

    def test_foreign_service_is_reused_and_never_signalled(self):
        with tempfile.TemporaryDirectory() as root, patch.object(service, 'kimi_endpoint', return_value={'port':58627,'token':'t'}), patch.object(service.os, 'kill') as kill, patch.object(service, 'installed_version') as version, patch.object(service.subprocess, 'Popen') as launch:
            self.assertEqual(service.ensure_kimi('/fixture/kimi', 58627, pathlib.Path(root)), {'port':58627,'token':'t'})
            kill.assert_not_called(); version.assert_not_called(); launch.assert_not_called()

    def test_record_of_a_dead_process_is_discarded(self):
        with tempfile.TemporaryDirectory() as root:
            home, record = owned_home(root, RECORD)
            with patch.object(service, 'alive', return_value=False), patch.object(service, 'kimi_endpoint', return_value={'port':58627,'token':'fixture-token'}), patch.object(service, 'stop_kimi') as stop:
                self.assertEqual(service.ensure_kimi('/fixture/kimi', 58627, home), {'port':58627,'token':'fixture-token'})
                stop.assert_not_called()
            self.assertFalse(record.exists())

    def test_reused_pid_with_another_start_time_is_not_owned(self):
        with tempfile.TemporaryDirectory() as root:
            home, record = owned_home(root, RECORD)
            other = dict(META, started_at='2026-10-23T00:00:00.000Z', server_version='2.2.0')
            with patch.object(service, 'alive', return_value=True), patch.object(service, 'kimi_meta', return_value=other), patch.object(service, 'kimi_endpoint', return_value={'port':58627,'token':'fixture-token'}), patch.object(service, 'stop_kimi') as stop, patch.object(service, 'installed_version', return_value='2.4.0'):
                self.assertEqual(service.ensure_kimi('/fixture/kimi', 58627, home), {'port':58627,'token':'fixture-token'})
                stop.assert_not_called()
            self.assertFalse(record.exists())

    def test_current_owned_service_reports_both_versions(self):
        with tempfile.TemporaryDirectory() as root:
            home, _ = owned_home(root, RECORD)
            with patch.object(service, 'alive', return_value=True), patch.object(service, 'kimi_meta', return_value=META), patch.object(service, 'installed_version', return_value='2.3.0'), patch.object(service, 'busy_sessions') as busy, patch.object(service, 'stop_kimi') as stop:
                self.assertEqual(service.ensure_kimi('/fixture/kimi', 58627, home),
                                 {'port':58627,'token':'fixture-token','owned':True,'runningVersion':'2.3.0','installedVersion':'2.3.0'})
                busy.assert_not_called(); stop.assert_not_called()

    def test_update_waits_while_sessions_are_busy(self):
        with tempfile.TemporaryDirectory() as root:
            home, _ = owned_home(root, RECORD)
            with patch.object(service, 'alive', return_value=True), patch.object(service, 'kimi_meta', return_value=META), patch.object(service, 'installed_version', return_value='2.4.0'), patch.object(service, 'busy_sessions', return_value=2), patch.object(service, 'stop_kimi') as stop:
                endpoint = service.ensure_kimi('/fixture/kimi', 58627, home)
                stop.assert_not_called()
            self.assertEqual((endpoint['restartPending'], endpoint['restartReason']), (2, 'update'))
            self.assertEqual((endpoint['installedVersion'], endpoint['runningVersion']), ('2.4.0', '2.3.0'))

    def test_unreadable_sessions_are_never_treated_as_idle(self):
        with tempfile.TemporaryDirectory() as root:
            home, _ = owned_home(root, RECORD)
            with patch.object(service, 'alive', return_value=True), patch.object(service, 'kimi_meta', return_value=META), patch.object(service, 'installed_version', return_value='2.4.0'), patch.object(service, 'busy_sessions', return_value=None), patch.object(service, 'stop_kimi') as stop:
                self.assertEqual(service.ensure_kimi('/fixture/kimi', 58627, home)['restartPending'], -1)
                stop.assert_not_called()

    def test_idle_update_replaces_the_service_on_its_port(self):
        with tempfile.TemporaryDirectory() as root:
            home, record = owned_home(root, dict(RECORD, port=58628))
            started = {'port':58628,'token':'fixture-token','owned':True}
            with patch.object(service, 'alive', return_value=True), patch.object(service, 'kimi_meta', return_value=META), patch.object(service, 'installed_version', return_value='2.4.0'), patch.object(service, 'busy_sessions', return_value=0), patch.object(service, 'stop_kimi', return_value=True) as stop, patch.object(service, 'start_kimi', return_value=started) as start:
                endpoint = service.ensure_kimi('/fixture/kimi', 58627, home, stop_timeout=12)
            stop.assert_called_once_with(4242, 58628, 12)
            self.assertEqual(start.call_args[0][1], 58628)
            self.assertEqual(start.call_args[0][8], '2.4.0')
            self.assertTrue(endpoint['replaced'])
            self.assertEqual(endpoint['restartReason'], 'update')
            self.assertFalse(record.exists())

    def test_failed_stop_keeps_the_old_service(self):
        with tempfile.TemporaryDirectory() as root:
            home, record = owned_home(root, RECORD)
            with patch.object(service, 'alive', return_value=True), patch.object(service, 'kimi_meta', return_value=META), patch.object(service, 'installed_version', return_value='2.4.0'), patch.object(service, 'busy_sessions', return_value=0), patch.object(service, 'stop_kimi', return_value=False), patch.object(service, 'start_kimi') as start:
                self.assertEqual(service.ensure_kimi('/fixture/kimi', 58627, home)['restartPending'], -1)
                start.assert_not_called()
            self.assertTrue(record.exists())

    def test_a_replacement_that_did_not_take_effect_is_not_repeated(self):
        with tempfile.TemporaryDirectory() as root:
            home, _ = owned_home(root, dict(RECORD, replacedFor='2.4.0'))
            with patch.object(service, 'alive', return_value=True), patch.object(service, 'kimi_meta', return_value=META), patch.object(service, 'installed_version', return_value='2.4.0'), patch.object(service, 'busy_sessions') as busy, patch.object(service, 'stop_kimi') as stop:
                self.assertEqual(service.ensure_kimi('/fixture/kimi', 58627, home)['restartPending'], -1)
                busy.assert_not_called(); stop.assert_not_called()

    def test_changed_launch_environment_restarts_when_idle(self):
        with tempfile.TemporaryDirectory() as root:
            home, _ = owned_home(root, dict(RECORD, replacedFor='2.3.0'))
            with patch.object(service, 'alive', return_value=True), patch.object(service, 'kimi_meta', return_value=META), patch.object(service, 'installed_version', return_value='2.3.0'), patch.object(service, 'busy_sessions', return_value=0), patch.object(service, 'stop_kimi', return_value=True), patch.object(service, 'start_kimi', return_value={'port':58627,'token':'t','owned':True}) as start:
                endpoint = service.ensure_kimi('/fixture/kimi', 58627, home, environment={'KIMI_CODE_INFINITE_RETRY': 'true'})
            self.assertEqual(endpoint['restartReason'], 'settings')
            self.assertEqual(start.call_args[0][7], {'KIMI_CODE_INFINITE_RETRY': 'true'})
            self.assertEqual(start.call_args[0][8], '2.3.0')
            self.assertEqual(start.call_args[0][3]['KIMI_CODE_INFINITE_RETRY'], 'true')

    def test_busy_sessions_follow_pages_and_count_interactions(self):
        pages = [
            {'code': 0, 'data': {'has_more': True, 'items': [{'id': 's1', 'busy': False}, {'id': 's 2', 'busy': True}]}},
            {'code': 0, 'data': {'has_more': False, 'items': [{'id': 's3', 'busy': False, 'pending_interaction': 'approval'},
                                                               {'id': 's4', 'busy': False, 'pending_interaction': 'none', 'main_turn_active': False}]}},
        ]
        with patch.object(service, 'kimi_request', side_effect=pages) as request:
            self.assertEqual(service.busy_sessions(58627, 't'), 2)
        self.assertIn('before_id=s%202', request.call_args_list[1][0][2])

    def test_busy_sessions_without_a_readable_catalog_is_unknown(self):
        for response in [OSError('refused'), {'code': 1}, {'code': 0, 'data': {'items': [{'id': 's1'}]}},
                         {'code': 0, 'data': {'has_more': True, 'items': []}}]:
            effect = response if isinstance(response, Exception) else [response]
            with patch.object(service, 'kimi_request', side_effect=effect):
                self.assertIsNone(service.busy_sessions(58627, 't'))

    def test_stop_terminates_and_escalates_after_the_timeout(self):
        stubborn = subprocess.Popen([sys.executable, '-c', 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print(1, flush=True); time.sleep(60)'], stdout=subprocess.PIPE)
        polite = subprocess.Popen([sys.executable, '-c', 'import time; print(1, flush=True); time.sleep(60)'], stdout=subprocess.PIPE)
        try:
            stubborn.stdout.readline(); polite.stdout.readline()
            started = time.monotonic()
            self.assertTrue(service.stop_kimi(polite.pid, 9, 30))
            self.assertLess(time.monotonic() - started, 10)
            self.assertTrue(service.stop_kimi(stubborn.pid, 9, 0.5))
            self.assertFalse(service.alive(stubborn.pid))
        finally:
            for process in (stubborn, polite):
                if process.poll() is None: process.kill()
                process.wait(); process.stdout.close()

    def test_environment_entries_are_validated(self):
        self.assertEqual(service.parse_environment(['A=1', 'B_2=x=y', 'EMPTY=']), {'A': '1', 'B_2': 'x=y', 'EMPTY': ''})
        for entry in ['1A=2', 'NOVALUE', 'A B=1', 'A=line\nbreak']:
            with self.assertRaises(RuntimeError): service.parse_environment([entry])

    def test_streamed_loader_runs_the_script_without_a_file(self):
        payload = base64.b64encode(SCRIPT.read_bytes()).decode()
        result = subprocess.run([sys.executable, '-c', LOADER, payload, '--agent', 'kimi', '--binary', '/nonexistent/kimi'],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertIn('unavailable', result.stderr)

    def test_kimi_is_resolved_from_the_ssh_path(self):
        with tempfile.TemporaryDirectory() as root:
            kimi = pathlib.Path(root) / 'kimi'
            kimi.write_text('#!/bin/sh\n'); kimi.chmod(0o755)
            with patch.dict(service.os.environ, {'PATH': root}):
                self.assertEqual(service.resolve_kimi(), str(kimi))


if __name__ == '__main__': unittest.main()
