import argparse
from datetime import datetime
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--stdin", type=Path)
    parser.add_argument("--cwd", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command and command[0] == "--":
        command = command[1:]
    if not command or arguments.receipt.exists() or arguments.log.exists():
        raise ValueError("Command required; refusing to overwrite evidence")
    standard_input = arguments.stdin.read_bytes() if arguments.stdin else None
    started_at = datetime.now().astimezone().isoformat(timespec="seconds")
    with arguments.log.open("xb") as output:
        result = subprocess.run(command, input=standard_input, cwd=arguments.cwd,
                                stdout=output, stderr=subprocess.STDOUT)
    receipt = {
        "command": command,
        "started_at": started_at,
        "finished_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "process_return_code": result.returncode,
        "original_log": arguments.log.name,
    }
    if arguments.stdin:
        receipt["stdin_file"] = str(arguments.stdin)
    with arguments.receipt.open("x") as output:
        json.dump(receipt, output, ensure_ascii=False, indent=2)
        output.write("\n")
    print(json.dumps(receipt, ensure_ascii=False))
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
