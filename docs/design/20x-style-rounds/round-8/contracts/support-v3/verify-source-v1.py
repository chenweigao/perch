import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess


parser = argparse.ArgumentParser()
parser.add_argument("--plan", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
arguments = parser.parse_args()
plan = json.loads(arguments.plan.read_text())
head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
assert head == plan["head"]
actual = {relative: hashlib.sha256(Path(relative).read_bytes()).hexdigest()
          for relative in plan["source_hashes"]}
assert actual == plan["source_hashes"]
assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD", "--", "Sources", "Tests", "scripts"], text=True).strip()
result = {"schema_version": 1, "verified_at": datetime.now().astimezone().isoformat(timespec="seconds"),
          "head": head, "source_hashes": actual, "source_changes": 0}
with arguments.output.open("x") as output:
    json.dump(result, output, indent=2)
    output.write("\n")
print("Pinned source verification: PASS")
