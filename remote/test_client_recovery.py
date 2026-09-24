"""Real HTTP + bridge + subprocess, synthetic OMP. This is not SSH/model acceptance."""
import http.client
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent


class ClientRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        binary = self.root / "bin"
        binary.mkdir()
        worker = binary / "omp"
        worker.write_text(f"#!{sys.executable}\n" + (HERE / "fixtures/recovery-omp.py").read_text())
        worker.chmod(0o700)
        self.log = (self.root / "service.log").open("w")
        self.addCleanup(self.log.close)
        self.service = subprocess.Popen([sys.executable, str(HERE / "native-agent-service.py")],
            env=dict(os.environ, AWB_NATIVE_ROOT=str(self.root / "service"),
                     PERCH_RECOVERY_FIXTURE=str(self.root), PATH=str(binary) + os.pathsep + os.environ["PATH"]),
            stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log)
        self.addCleanup(self.stop_service)
        endpoint = self.root / "service/endpoint.json"
        self.until(lambda: endpoint.exists(), "bridge startup")
        self.endpoint = json.loads(endpoint.read_text())
        self.a, self.b = self.client(), self.client()
        code, session = self.request(self.a, "/sessions", {
            "provider": "omp", "cwd": str(self.root), "title": "Recovery fixture"})
        self.assertEqual(code, 200)
        self.path = "/sessions/" + session["id"]

    def stop_service(self):
        # Only the worker created in this test's private runtime can be signalled.
        pid_file = self.root / "worker.pid"
        if pid_file.exists():
            try:
                os.kill(int(pid_file.read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.service.terminate()
        try:
            self.service.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.service.kill()
            self.service.wait(timeout=5)

    def client(self):
        client = http.client.HTTPConnection("127.0.0.1", self.endpoint["port"], timeout=3)
        self.addCleanup(client.close)
        return client

    def request(self, client, path, body=None):
        client.request("GET" if body is None else "POST", path,
            body=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + self.endpoint["token"]})
        response = client.getresponse()
        return response.status, json.loads(response.read())

    def snapshot(self, client):
        code, snapshot = self.request(client, self.path)
        self.assertEqual(code, 200)
        return snapshot

    def until(self, condition, description):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            self.assertIsNone(self.service.poll(), (self.root / "service.log").read_text())
            value = condition()
            if value:
                return value
            time.sleep(.02)
        self.fail("Timed out: " + description)

    def commands(self, kind):
        path = self.root / "commands.jsonl"
        return [value for line in path.read_text().splitlines()
                if (value := json.loads(line))["type"] == kind]

    def test_lost_response_reconnect_and_completion_never_replay_prompt(self):
        body = {"text": "complete while disconnected", "requestId": "lost-response"}
        # Send the full request, then lose the transport before consuming its response.
        self.a.request("POST", self.path + "/prompt", json.dumps(body),
                       {"Authorization": "Bearer " + self.endpoint["token"]})
        self.a.close()
        receipt_path = self.path + "/requests/lost-response"
        self.until(lambda: self.request(self.b, receipt_path)[1]["status"] == "running", "runtime acceptance")
        running = self.snapshot(self.b)
        self.assertTrue(running["busy"])
        self.assertEqual(running["turnId"], body["requestId"])
        self.assertEqual(len([m for m in running["messages"] if m["role"] == "user"]), 1)
        self.b.close()
        (self.root / "release").touch()
        reconnected = self.client()
        self.until(lambda: not self.snapshot(reconnected)["busy"], "completion after disconnect")
        done = self.snapshot(reconnected)
        self.assertEqual(done["turnState"], "completed")
        self.assertEqual(done["completed"], 1)
        self.assertEqual(done["messages"][-1]["content"][0]["text"], "synthetic result")
        self.assertEqual(self.request(reconnected, self.path + "/prompt", body)[1]["status"], "completed")
        self.assertEqual(len(self.commands("prompt")), 1)

    def test_second_client_answers_approval_and_stops_only_current_turn(self):
        self.assertEqual(self.request(self.a, self.path + "/prompt", {
            "text": "ask before completing", "requestId": "approval-turn"})[0], 200)
        self.until(lambda: self.snapshot(self.a)["interactions"], "pending approval")
        self.a.close()
        pending = self.snapshot(self.b)
        self.assertTrue(pending["busy"])
        approval = pending["interactions"][0]["id"]
        self.assertEqual(self.commands("extension_ui_response"), [])
        answer = {"id": approval, "allow": True}
        self.assertEqual(self.request(self.b, self.path + "/answer", answer)[0], 200)
        self.until(lambda: not self.snapshot(self.b)["busy"], "approved completion")
        self.assertEqual(self.request(self.client(), self.path + "/answer", answer)[0], 400)
        self.assertEqual(len(self.commands("extension_ui_response")), 1)
        self.assertEqual(self.snapshot(self.b)["interactions"], [])
        self.assertEqual(self.request(self.b, self.path + "/prompt", {
            "text": "wait for stop", "requestId": "next-turn"})[0], 200)
        self.until(lambda: self.snapshot(self.b)["turnState"] == "running", "next turn")
        other = self.client()
        self.assertEqual(self.request(other, self.path + "/abort", {"turnId": "approval-turn"})[0], 400)
        self.assertEqual(self.commands("abort"), [])
        self.assertEqual(self.request(other, self.path + "/abort", {"turnId": "next-turn"})[0], 200)
        self.until(lambda: not self.snapshot(other)["busy"], "stop acknowledgement")
        stopped = self.snapshot(other)
        self.assertEqual(stopped["turnState"], "stopped")
        self.assertEqual(stopped["completed"], 1, "a stopped turn must not count as another completed result")
        self.assertEqual(len(self.commands("abort")), 1)


if __name__ == "__main__":
    unittest.main()
