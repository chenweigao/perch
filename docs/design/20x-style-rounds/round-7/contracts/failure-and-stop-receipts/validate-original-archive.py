import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--remote-sha256", required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-pngs", type=int)
    arguments = parser.parse_args()
    if arguments.destination.exists() or arguments.output.exists():
        raise ValueError("Refusing to overwrite original evidence")
    archive_sha256 = hashlib.sha256(arguments.archive.read_bytes()).hexdigest()
    if archive_sha256 != arguments.remote_sha256:
        raise ValueError("Mac and local archive hashes differ")
    files = {}
    normalized_names = set()
    png_count = 0
    with tarfile.open(arguments.archive, "r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            relative = PurePosixPath(member.name)
            if (relative.is_absolute() or ".." in relative.parts or "\\" in member.name
                    or not relative.parts or relative.as_posix() != member.name.rstrip("/")
                    or relative.as_posix() in normalized_names
                    or any(part.startswith("._") or part == ".DS_Store" for part in relative.parts)
                    or not (member.isfile() or member.isdir())):
                raise ValueError(f"Unsafe, duplicate or metadata archive entry: {member.name}")
            normalized_names.add(relative.as_posix())
            if member.isfile():
                payload = archive.extractfile(member).read()
                if len(payload) != member.size:
                    raise ValueError(f"Truncated archive entry: {member.name}")
                files[relative.as_posix()] = hashlib.sha256(payload).hexdigest()
                if relative.suffix.lower() == ".png":
                    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
                        raise ValueError(f"Invalid PNG original: {member.name}")
                    png_count += 1
        if arguments.expected_pngs is not None and png_count != arguments.expected_pngs:
            raise ValueError(f"Unexpected PNG count: {png_count}")
        archive.extractall(arguments.destination, filter="data")
    for relative, expected in files.items():
        source = arguments.destination / relative
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"Non-regular extracted original: {relative}")
        if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Extracted original bytes differ: {relative}")
    result = {
        "status": "passed",
        "verified_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "archive_sha256": archive_sha256,
        "mac_and_local_archive_sha256_equal": True,
        "members": len(members),
        "regular_files": len(files),
        "original_pngs": png_count,
        "all_member_bytes_verified": True,
        "unsafe_paths_or_links": 0,
        "appledouble_metadata": 0,
        "extraction_filter": "data",
        "GUI_restarted": False,
    }
    with arguments.output.open("x") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
