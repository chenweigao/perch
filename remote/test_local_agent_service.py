import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('local_service', pathlib.Path(__file__).with_name('local-agent-service.py'))
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)

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

    def test_fresh_service_is_detached_and_authenticated(self):
        with tempfile.TemporaryDirectory() as root, patch.object(service, 'kimi_endpoint',side_effect=[None, {'port':58627,'token':'test'}]), patch.object(service.subprocess,'Popen') as launch, patch.object(service.time,'sleep'):
            service.ensure_kimi('/path with spaces/kimi', 58627, pathlib.Path(root))
            args, kwargs = launch.call_args
            self.assertEqual(args[0], ['/path with spaces/kimi','web','--host','127.0.0.1','--port','58627','--no-open'])
            self.assertTrue(kwargs['start_new_session'])
            self.assertEqual(kwargs['stdin'], service.subprocess.DEVNULL)
            self.assertNotIn('--dangerous-bypass-auth', args[0])

    def test_timeout_is_not_treated_as_missing_service(self):
        with tempfile.TemporaryDirectory() as root, patch.object(service.urllib.request,'urlopen',side_effect=urllib.error.URLError(TimeoutError())), patch.object(service.subprocess,'Popen') as launch:
            with self.assertRaises(RuntimeError): service.ensure_kimi('/fixture/kimi',58627,pathlib.Path(root))
            launch.assert_not_called()

if __name__ == '__main__': unittest.main()
