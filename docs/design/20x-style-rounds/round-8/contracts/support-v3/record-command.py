import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--stdin", type=Path)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    assert command
    log_path = arguments.directory / (arguments.name + ".log")
    receipt_path = arguments.directory / (arguments.name + ".receipt.json")
    started = datetime.now().astimezone().isoformat(timespec="seconds")
    status = None
    exception = None
    with log_path.open("xb") as log:
        try:
            result = subprocess.run(command, input=arguments.stdin.read_bytes() if arguments.stdin else None,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=arguments.timeout,
                                    env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", PYTHONDONTWRITEBYTECODE="1"))
            status = result.returncode
        except subprocess.TimeoutExpired as error:
            exception = {"type": type(error).__name__, "timeout": arguments.timeout}
        except OSError as error:
            exception = {"type": type(error).__name__, "errno": error.errno}
    receipt = {"schema_version": 1, "command": command, "started_at": started,
               "finished_at": datetime.now().astimezone().isoformat(timespec="seconds"),
               "process_exit": status, "exception": exception,
               "stdin_sha256": hashlib.sha256(arguments.stdin.read_bytes()).hexdigest() if arguments.stdin else None,
               "log_sha256": hashlib.sha256(log_path.read_bytes()).hexdigest()}
    with receipt_path.open("x") as output:
        json.dump(receipt, output, ensure_ascii=False, indent=2)
        output.write("\n")
    print(log_path.read_text(errors="replace"), end="")
    print(json.dumps(receipt, ensure_ascii=False))
    raise SystemExit(status if status is not None and status >= 0 else 124 if exception else 1)


if __name__ == "__main__":
    main()
