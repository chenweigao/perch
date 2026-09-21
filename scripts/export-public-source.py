#!/usr/bin/env python3
"""Export and check committed source, without Git history or any network operation."""
import argparse
import io
import pathlib
import posixpath
import subprocess
import sys
import tarfile


def extract_source(archive, target):
    """Preserve source links only when they target a regular file in this archive."""
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        members = {member.name: member for member in source.getmembers()}
        links = []
        for member in members.values():
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Archive entry needs manual review: " + member.name)
            payload = member
            if member.issym():
                link = pathlib.PurePosixPath(member.linkname)
                destination = posixpath.normpath(str(path.parent / link))
                payload = members.get(destination)
                if link.is_absolute() or destination.startswith("../") or payload is None or not payload.isfile():
                    raise ValueError("Archive link must target an included regular file: " + member.name)
                links.append(member)
                continue
            elif not (member.isfile() or member.isdir()):
                raise ValueError("Archive entry needs manual review: " + member.name)
            output = target / path
            if member.isdir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(source.extractfile(payload).read())
                output.chmod(payload.mode & 0o777)
        # Create links last so extraction never writes through one.
        for member in links:
            output = target / member.name
            output.parent.mkdir(parents=True, exist_ok=True)
            output.symlink_to(member.linkname)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", help="A new directory; an existing path is never overwritten")
    parser.add_argument("--ref", default="HEAD", help="Committed source to export (default: HEAD)")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    target = pathlib.Path(args.destination).resolve()
    if target.exists():
        parser.error("Destination exists. Choose a new directory.")
    revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "--verify", args.ref + "^{commit}"], text=True).strip()
    archive = subprocess.check_output(["git", "-C", str(root), "archive", "--format=tar", revision])
    target.mkdir(parents=True, mode=0o700)
    extract_source(archive, target)
    if not (target / "LICENSE").is_file():
        raise ValueError("No LICENSE in snapshot; source is staged but not ready for publication.")
    subprocess.run([sys.executable, str(target / "scripts/check-public-source.py"), "--snapshot", str(target)], check=True)
    print("Source revision:", revision)
    print("Checked snapshot:", target)
    print("No .git directory, history, remote, commit identity or upload was created.")
    print("Review assets, license and final acceptance before initializing a NEW public repository.")


if __name__ == "__main__":
    main()
