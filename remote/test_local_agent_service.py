import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).with_name('local-agent-service.py')
spec = importlib.util.spec_from_file_location('local_agent_service', SCRIPT)
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class LocalAgentServiceTests(unittest.TestCase):
    def make_binary(self, folder, name):
        binary = pathlib.Path(folder) / name
        binary.write_text('#!/bin/sh\n')
        binary.chmod(0o755)
        return str(binary)

    def test_kimi_and_codex_delegate_to_the_local_native_bridge(self):
        with tempfile.TemporaryDirectory() as root:
            kimi_dir = pathlib.Path(root) / 'kimi bin'
            codex_dir = pathlib.Path(root) / 'codex bin'
            kimi_dir.mkdir()
            codex_dir.mkdir()
            kimi = self.make_binary(kimi_dir, 'kimi')
            codex = self.make_binary(codex_dir, 'codex')
            env = service.build_bridge_environment(
                kimi_binary=kimi,
                codex_binary=codex,
                base_env={'PATH': '/usr/bin:/bin'},
                home=root,
            )
            self.assertEqual(env['PERCH_LOCAL_KIMI'], kimi)
            self.assertEqual(env['PERCH_LOCAL_CODEX'], codex)
            self.assertEqual(
                env['AWB_NATIVE_ROOT'],
                str(pathlib.Path(root) / '.local/share/perch/local-native'),
            )
            self.assertEqual(
                env['PATH'].split(os.pathsep)[:3],
                [str(kimi_dir), str(codex_dir), '/usr/bin'],
            )

    def test_single_agent_clears_unselected_local_override(self):
        with tempfile.TemporaryDirectory() as root:
            kimi = self.make_binary(root, 'kimi')
            env = service.build_bridge_environment(
                kimi_binary=kimi,
                base_env={'PATH': '/usr/bin', 'PERCH_LOCAL_CODEX': '/stale/codex'},
                home=root,
            )
            self.assertEqual(env['PERCH_LOCAL_KIMI'], kimi)
            self.assertNotIn('PERCH_LOCAL_CODEX', env)

    def test_missing_or_relative_executable_is_rejected(self):
        for invalid in ('', 'kimi', '/nonexistent/kimi'):
            with self.assertRaisesRegex(RuntimeError, 'unavailable'):
                service.validate_binary(invalid)
        with self.assertRaisesRegex(RuntimeError, 'Select at least one'):
            service.build_bridge_environment(base_env={'PATH': '/usr/bin'})

    def test_main_execs_native_agent_service_ensure(self):
        with tempfile.TemporaryDirectory() as root:
            kimi = self.make_binary(root, 'kimi')
            with patch.object(sys, 'argv', ['local-agent-service.py', '--agent', 'kimi', '--binary', kimi]), \
                 patch.object(service.os, 'execv') as execv, \
                 patch.dict(service.os.environ, {'PATH': '/usr/bin'}, clear=True):
                service.main()
                self.assertEqual(service.os.environ['PERCH_LOCAL_KIMI'], kimi)
                self.assertTrue(service.os.environ['AWB_NATIVE_ROOT'].endswith('/.local/share/perch/local-native'))
                expected = str(SCRIPT.with_name('native-agent-service.py'))
                execv.assert_called_once_with(sys.executable, [sys.executable, expected, '--ensure'])

    def test_cli_rejects_unavailable_binary_before_starting_bridge(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), '--agent', 'kimi', '--binary', '/nonexistent/kimi'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn('unavailable', result.stderr)

    def test_kimi_is_resolved_from_path_or_npm_prefix(self):
        with tempfile.TemporaryDirectory() as root:
            kimi = self.make_binary(root, 'kimi')
            with patch.dict(service.os.environ, {'PATH': root}):
                self.assertEqual(service.resolve_kimi(), kimi)


if __name__ == '__main__':
    unittest.main()
