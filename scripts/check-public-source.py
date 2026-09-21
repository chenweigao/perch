#!/usr/bin/env python3
"""Check publication candidates without printing matched secrets. Not a full secret audit."""
import argparse
import pathlib
import os
import re
import subprocess
import sys

RULES = {
    "private-key": re.compile(rb"-----BEGIN (?:OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----"),
    "token": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{25,}|sk-[A-Za-z0-9_-]{24,}|AKIA[A-Z0-9]{16})\b"),
    "credential-value": re.compile(rb"(?i)(?:api[_-]?key|access[_-]?token|secret|password)\s*[=:]\s*[\x22\x27][^\x22\x27\s]{16,}[\x22\x27]"),
    "personal-path": re.compile(rb"/(?:Users|home)/[A-Za-z0-9_.-]+/"),
    "private-ip": re.compile(rb"\b(?:10|11)\.(?:\d{1,3}\.){2}\d{1,3}\b|\b192\.168\.\d{1,3}\.\d{1,3}\b|\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b"),
    "bearer-value": re.compile(rb"(?i)Bearer\s+[A-Za-z0-9._-]{20,}"),
    "email": re.compile(rb"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"),
}


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def publication_paths(root):
    paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
    paths = sorted(set(p for p in paths if p))
    attrs = subprocess.check_output(
        ["git", "-C", str(root), "check-attr", "--stdin", "-z", "export-ignore"],
        input=b"\0".join(paths) + b"\0",
    ).split(b"\0")
    # Directory export-ignore applies recursively in git archive, so query parents too.
    excluded = {attrs[i] for i in range(0, len(attrs) - 1, 3) if attrs[i + 2] == b"set"}
    output = []
    for raw in paths:
        path = pathlib.PurePosixPath(raw.decode())
        if raw in excluded:
            continue
        for parent in path.parents:
            if str(parent) == ".":
                continue
            value = git(root, "check-attr", "export-ignore", "--", str(parent)).decode().strip()
            if value.endswith(": set"):
                break
        else:
            output.append(root / path)
    return output


def findings(label, data):
    # JSON serializers may escape path separators; scan the equivalent plain path.
    data = data.replace(bytes([92, 47]), b"/")
    count = 0
    for rule, pattern in RULES.items():
        for match in pattern.finditer(data):
            if rule == "personal-path" and match.group() in (b"/home/user/", b"/home/developer/", b"/Users/developer/"):
                continue
            if rule == "email" and (match.group().split(b"@")[-1] in (b"example.com", b"example.org", b"example.test") or match.group().split(b"@")[-1].endswith(b".example")):
                continue
            line = data.count(b"\n", 0, match.start()) + 1
            print(f"{label}:{line}: {rule}")
            count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--snapshot", action="store_true", help="Scan every file in an exported directory, without Git")
    parser.add_argument("--history", action="store_true", help="Also scan all reachable blobs and commit identities; never changes history")
    args = parser.parse_args()
    root = pathlib.Path(args.root).resolve()
    if args.snapshot and args.history:
        parser.error("--snapshot and --history are mutually exclusive")
    paths = sorted(p for p in root.rglob("*") if p.is_file() or p.is_symlink()) if args.snapshot else publication_paths(root)
    included = set(paths)
    count = 0
    for path in paths:
        label = str(path.relative_to(root))
        if path.name == ".env" or (path.name.startswith(".env.") and path.name != ".env.example") or path.suffix in (".pem", ".key") or ".session-export" in path.parts:
            print(f"{label}: private file type")
            count += 1
        if path.is_symlink():
            link = path.readlink()
            target = pathlib.Path(os.path.normpath(path.parent / link))
            if link.is_absolute() or target not in included or target.is_symlink() or not target.is_file():
                print(f"{label}: symlink requires manual review")
                count += 1
                continue
        if path.exists():
            count += findings(label, path.read_bytes())
    if args.history:
        # This deliberately includes export-ignored historical files and author emails.
        count += findings("git-identities", git(root, "log", "--all", "--format=%an <%ae>%n%cn <%ce>"))
        for entry in git(root, "rev-list", "--objects", "--all").splitlines():
            oid, _, name = entry.partition(b" ")
            if not name or git(root, "cat-file", "-t", oid.decode()).strip() != b"blob":
                continue
            count += findings("history/" + oid[:12].decode() + "/" + name.decode(), git(root, "cat-file", "blob", oid.decode()))
    print(f"Checked {len(paths)} publication files; {count} finding(s). Matched values are never printed.")
    print("Pattern checks do not verify image content, unknown credential formats, ownership or licensing.")
    return 1 if count else 0


if __name__ == "__main__":
    sys.exit(main())
