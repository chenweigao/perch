"""Run the packaged installer against recording SSH/SCP executables, never a host."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]

class InstallerTests(unittest.TestCase):
    def run_installer(self, *arguments):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name in ('ssh', 'scp'):
                binary = folder / name
                binary.write_text('#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ["SETUP_RECORD"], "a") as f: f.write(json.dumps(sys.argv) + "\\n")\n')
                binary.chmod(0o700)
            env = dict(os.environ, PATH=str(folder) + os.pathsep + os.environ['PATH'], SETUP_RECORD=str(folder / 'record'))
            result = subprocess.run(['bash', str(ROOT / 'scripts/install-native-service.sh'), *arguments], env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in (folder / 'record').read_text().splitlines()] if (folder / 'record').exists() else []
            return result, calls

    def test_omp_does_not_install_qoder_or_require_npm(self):
        result, calls = self.run_installer('fixture', '--provider=omp')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertNotIn('npm', json.dumps(calls))
        self.assertNotIn('pip', json.dumps(calls))
        for call in calls:
            self.assertIn('StrictHostKeyChecking=yes', call)
            self.assertIn('BatchMode=yes', call)

    def test_codex_only_deploys_bridge_files(self):
        result, calls = self.run_installer('fixture', '--provider=codex')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertNotIn('npm', json.dumps(calls))
        self.assertNotIn('pip', json.dumps(calls))

    def test_qoder_installs_sdk_without_lifecycle_scripts(self):
        result, calls = self.run_installer('fixture', '--provider=qoder')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('npm install --ignore-scripts', calls[-1][-1])
        self.assertNotIn('pip', json.dumps(calls))

    def test_dsh_installs_pinned_runtime_without_npm(self):
        result, calls = self.run_installer('fixture', '--provider=dsh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('deepseek-harness-sdk==0.1.5rc1', calls[-1][-1])
        self.assertNotIn('npm', json.dumps(calls))
        self.assertNotIn('kill', json.dumps(calls))

    def test_missing_or_option_host_never_runs_ssh(self):
        for arguments in [(), ('-oProxyCommand=bad',)]:
            result, calls = self.run_installer(*arguments)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(calls, [])

    def test_cancel_stops_local_client_and_closes_output_pipes(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'ssh'
            binary.write_text('#!/usr/bin/env python3\nimport os, time\nprint(os.getpid(), flush=True)\ntime.sleep(5)\n')
            binary.chmod(0o700)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'])
            with subprocess.Popen(['bash', str(ROOT / 'scripts/install-native-service.sh'), 'fixture', '--provider=omp'],
                                  env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
                client = int(process.stdout.readline())
                started = time.monotonic()
                process.terminate()
                process.communicate(timeout=3)
                self.assertLess(time.monotonic() - started, 3)
                self.assertEqual(process.returncode, 130)
                with self.assertRaises(ProcessLookupError): os.kill(client, 0)

if __name__ == '__main__': unittest.main()
