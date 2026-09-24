"""Synthetic OMP RPC worker. No model, tools, credentials or network access."""
import json
import os
from pathlib import Path
import sys
import threading
import time

root = Path(os.environ["PERCH_RECOVERY_FIXTURE"])
(root / "worker.pid").write_text(str(os.getpid()))
output_lock = threading.Lock()
turn = None


def emit(value):
    with output_lock:
        print(json.dumps(value), flush=True)


def finish(timestamp, stopped=False):
    emit({"type": "message_end", "message": {
        "role": "assistant", "timestamp": timestamp,
        "content": [{"type": "text", "text": "stopped" if stopped else "synthetic result"}],
        "stopReason": "aborted" if stopped else "stop"}})
    emit({"type": "agent_end"})


def await_release(timestamp):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if (root / "release").exists():
            finish(timestamp)
            return
        time.sleep(.01)
    emit({"type": "worker_error", "message": "fixture release timed out"})


for line in sys.stdin:
    message = json.loads(line)
    with (root / "commands.jsonl").open("a") as log:
        log.write(json.dumps(message) + "\n")
    kind = message["type"]
    if kind == "prompt":
        turn = message["id"]
        emit({"type": "response", "command": "prompt", "id": turn, "success": True})
        emit({"type": "agent_start"})
        emit({"type": "message_end", "message": {
            "role": "user", "timestamp": turn, "content": message["message"]}})
        if message["message"] == "complete while disconnected":
            threading.Thread(target=await_release, args=(turn,), daemon=True).start()
        elif message["message"] == "ask before completing":
            emit({"type": "extension_ui_request", "id": "approval-" + turn,
                  "method": "confirm", "title": "Allow synthetic result?"})
        # Other prompts remain running until an explicit abort.
    elif kind == "extension_ui_response":
        finish(turn)
    elif kind == "abort":
        finish(turn, stopped=True)
    elif kind == "get_state":
        emit({"type": "response", "command": "get_state", "success": True,
              "data": {"sessionFile": str(root / "synthetic.jsonl")}})
