#!/usr/bin/env python3
"""Check the Codex app-server wire protocol against the bridge's actual usage.

The bridge (remote/native-agent-service.py) speaks JSON-RPC to
`codex app-server --listen stdio://`. A Codex upgrade can rename or drop a
method; this check regenerates the official JSON schema from the installed
CLI and fails on any method the bridge uses that the schema no longer
declares, so upgrades get a deterministic signal instead of a manual review.

Runs offline against a pregenerated schema with --schema-dir. Without a codex
CLI the check skips cleanly so CI hosts without codex keep passing.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "remote" / "native-agent-service.py"

# Codex wire families the bridge speaks. ACP (`session/`), display tool names
# (`agent/spawnAgent`) and MIME types share the slash shape but are not Codex
# methods. The bare names predate the namespaced methods.
PREFIXES = ("thread/", "turn/", "item/", "account/", "model/", "mcpServer/", "serverRequest/")
BARE = ("initialize", "initialized", "execCommandApproval", "applyPatchApproval")
LITERAL = re.compile(r"'([^']+)'")
# Call sites that pass the method through a variable defeat the line-level
# call-site check; their direction is declared here instead.
DIRECTION_OVERRIDES = {"thread/archive": "request", "thread/unarchive": "request"}

SCHEMA_FILES = {
    "request": "ClientRequest.json",            # bridge -> server requests
    "notify": "ClientNotification.json",        # bridge -> server notifications
    "incoming": ("ServerNotification.json", "ServerRequest.json"),
}


def bridge_methods(source):
    """Wire methods the bridge references, classified by call-site direction."""
    used = {}
    for line in source.splitlines():
        for match in LITERAL.finditer(line):
            value = match.group(1)
            if not (value.startswith(PREFIXES) or value in BARE):
                continue
            call = re.search(r"\.(request|notify)\(\s*'" + re.escape(value) + r"'", line)
            direction = DIRECTION_OVERRIDES.get(value) or (call.group(1) if call else "incoming")
            # A method seen at a call site is outgoing wherever else it appears.
            rank = {"incoming": 0, "notify": 1, "request": 2}
            if rank[direction] > rank.get(used.get(value), -1):
                used[value] = direction
    return used


def schema_methods(path):
    """Method names a schema file declares: the single-value `method` enums."""
    text = path.read_text(encoding="utf-8")
    return set(re.findall(r'"enum"\s*:\s*\[\s*"([^"]+)"\s*\]', text))


def generate_schema(binary):
    out = tempfile.TemporaryDirectory(prefix="codex-schema-")
    result = subprocess.run(
        [binary, "app-server", "generate-json-schema", "--experimental", "--out", out.name],
        capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        out.cleanup()
        raise SystemExit("codex app-server generate-json-schema failed: " + result.stderr.strip())
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--schema-dir", type=Path, help="Pregenerated schema output to check instead of running codex")
    parser.add_argument("--codex", help="Codex CLI to query (default: PERCH_LOCAL_CODEX or PATH)")
    args = parser.parse_args()

    used = bridge_methods(BRIDGE.read_text(encoding="utf-8"))
    if not used:
        print("FAIL: no Codex wire methods found in", BRIDGE)
        return 1

    generated = None
    schema_dir = args.schema_dir
    if schema_dir is None:
        binary = args.codex or os.environ.get("PERCH_LOCAL_CODEX") or shutil.which("codex")
        if not binary:
            print("SKIP: no codex CLI found; install codex or pass --schema-dir")
            return 0
        version = subprocess.run([binary, "--version"], capture_output=True, text=True).stdout.strip()
        generated = generate_schema(binary)
        schema_dir = Path(generated.name)
        print("codex:", version)
    try:
        available = {}
        for direction, names in SCHEMA_FILES.items():
            files = (names,) if isinstance(names, str) else names
            found = set()
            for name in files:
                path = schema_dir / name
                if not path.exists():
                    print("FAIL: schema file missing:", path)
                    return 1
                found |= schema_methods(path)
            available[direction] = found

        missing = [(method, direction) for method, direction in sorted(used.items())
                   if method not in available[direction]]
        for method, direction in sorted(used.items()):
            state = "missing" if (method, direction) in missing else "ok"
            print(f"{state:>7}  {method}  ({direction})")
        unused = sorted(m for m in available["request"] if "/" in m and m not in used)
        if unused:
            print("info: schema requests the bridge does not use (review candidates):", ", ".join(unused))
        if missing:
            print(f"FAIL: {len(missing)} bridge method(s) absent from the codex schema")
            return 1
        print(f"OK: {len(used)} bridge methods declared by the codex schema")
        return 0
    finally:
        if generated is not None:
            generated.cleanup()


if __name__ == "__main__":
    sys.exit(main())
