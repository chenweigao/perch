#!/usr/bin/env python3
"""Check the declared versions and, optionally, the build identity of a bundle."""
import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_PLIST = ROOT / "Resources/Info.plist"
RELEASE = re.compile(r"^\d+\.\d+\.\d+$")
BUILD = re.compile(r"^\d+$")
# The client and the bridge it installs must agree on one protocol version.
BRIDGE = [(Path("Sources/WorkbenchCore/RemoteSetup.swift"), re.compile(r"^\s*public static let bridgeServiceVersion = (\d+)$", re.M)),
          (Path("remote/native-agent-service.py"), re.compile(r"^SERVICE_VERSION = (\d+)$", re.M))]


def git(*arguments):
    result = subprocess.run(["git", *arguments], cwd=ROOT, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def bridge_versions(failures):
    versions = {}
    for path, pattern in BRIDGE:
        found = pattern.findall((ROOT / path).read_text(encoding="utf-8"))
        if len(found) != 1:
            failures.append(f"{path} declares {len(found)} bridge protocol versions; expected exactly one")
        else:
            versions[path] = int(found[0])
    return versions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Built bundle to check for a stamped build identity")
    args = parser.parse_args()
    failures = []
    source = plistlib.loads(SOURCE_PLIST.read_bytes())
    version = source.get("CFBundleShortVersionString")
    if not isinstance(version, str) or not RELEASE.match(version):
        failures.append(f"Resources/Info.plist CFBundleShortVersionString is {version!r}; expected MAJOR.MINOR.PATCH")
        version = None

    tags = git("tag", "--points-at", "HEAD")
    if tags is None:
        print("No Git metadata; skipped the release tag comparison")
    else:
        releases = [tag for tag in tags.splitlines() if RELEASE.match(tag.removeprefix("v"))]
        if not releases:
            print("HEAD carries no release tag; skipped the release tag comparison")
        elif version is not None and releases != ["v" + version]:
            failures.append(f"HEAD is tagged {', '.join(releases)} but declares version {version}; "
                            "bump Resources/Info.plist before tagging a release")
        else:
            print(f"HEAD is tagged {', '.join(releases)} and declares the same version")

    bridge = bridge_versions(failures)
    if len(set(bridge.values())) > 1:
        failures.append("the bridge protocol version differs between "
                        + " and ".join(f"{path} (v{found})" for path, found in bridge.items())
                        + "; a client must speak the version of the bridge it installs")
    elif bridge:
        print(f"Bridge protocol v{next(iter(bridge.values()))} in client and service")

    if args.app:
        bundle = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
        if version is not None and bundle.get("CFBundleShortVersionString") != version:
            failures.append(f"{args.app} declares version {bundle.get('CFBundleShortVersionString')!r}, "
                            f"not {version!r}")
        build = bundle.get("CFBundleVersion")
        if not isinstance(build, str) or not BUILD.match(build):
            failures.append(f"{args.app} CFBundleVersion is {build!r}; expected the commit count")
        revision = bundle.get("PerchSourceRevision")
        if not isinstance(revision, str) or not revision:
            failures.append(f"{args.app} carries no PerchSourceRevision; rebuild it with scripts/build.sh")
        else:
            print(f"{args.app}: {version} build {build} ({revision})")

    for failure in failures:
        print("Failed: " + failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
