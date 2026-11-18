import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


TEXT_SUFFIXES = {".log", ".json", ".md", ".txt", ".diff", ".done"}
PERSONAL_PATH = re.compile(r"/(Users|home)/[A-Za-z0-9_.-]+/")
ESCAPED_PERSONAL_PATH = re.compile(r"\\/(Users|home)\\/[A-Za-z0-9_.-]+\\/")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise ValueError("Publication destination must be new; raw artifacts remain untouched")
    arguments.output.mkdir(parents=True)
    archived, redacted, image_hashes = [], [], {}
    for source in sorted(arguments.input.rglob("*")):
        if not source.is_file() or any(part.endswith(".app") for part in source.parts):
            continue
        relative = source.relative_to(arguments.input)
        destination = arguments.output / relative
        if source.suffix == ".png":
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
                raise ValueError("Published screenshot bytes changed")
            image_hashes[str(relative)] = digest
        elif source.suffix in TEXT_SUFFIXES:
            original = source.read_text()
            published = PERSONAL_PATH.sub(lambda match: f"/{match.group(1)}/developer/", original)
            published = ESCAPED_PERSONAL_PATH.sub(
                lambda match: f"\\/{match.group(1)}\\/developer\\/", published,
            )
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(published)
            if original != published:
                redacted.append(str(relative))
        else:
            continue
        archived.append(str(relative))
    summary = {
        "scope": "Publication copies only; raw text and screenshots are not rewritten",
        "archived_files": len(archived),
        "path_redacted_files": redacted,
        "unchanged_png_sha256": image_hashes,
        "excluded": "App bundles and non-evidence binary files",
    }
    (arguments.output / "archive-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"archived": len(archived), "path_redacted": len(redacted),
                      "unchanged_pngs": len(image_hashes)}))


if __name__ == "__main__":
    main()
