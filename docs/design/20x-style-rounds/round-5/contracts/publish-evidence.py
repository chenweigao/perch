import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


PERSONAL_HOME = re.compile(r"/(Users|home)/[A-Za-z0-9_.-]+/")


def digest(source):
    return hashlib.sha256(source.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    arguments = parser.parse_args()
    if not arguments.source.is_dir() or arguments.destination.exists():
        raise ValueError("Source must exist and publication destination must be new")
    sources = sorted(source for source in arguments.source.rglob("*") if source.is_file())
    protected = [(source, digest(source)) for source in sources]
    arguments.destination.mkdir(parents=True)
    records = []
    for source, original_hash in protected:
        if source.is_symlink():
            raise ValueError("Evidence symlinks must not be followed for publication")
        relative = source.relative_to(arguments.source)
        destination = arguments.destination / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.suffix == ".png":
            shutil.copyfile(source, destination)
            if digest(destination) != original_hash:
                raise ValueError("Publication must preserve original PNG bytes")
        else:
            original = source.read_bytes().decode("utf-8")
            normalized = original.replace("\\/", "/")
            published = PERSONAL_HOME.sub(lambda match: f"/{match.group(1)}/developer/", normalized)
            destination.write_text(published)
        records.append({"file": str(relative), "source_sha256": original_hash,
                        "published_sha256": digest(destination), "png_bytes_preserved": source.suffix == ".png"})
    unchanged = all(digest(source) == original_hash for source, original_hash in protected)
    report = {"status": "passed" if unchanged else "failed", "source_files": len(sources),
              "originals_unchanged": unchanged, "png_count": sum(record["png_bytes_preserved"] for record in records),
              "text_policy": "Only machine home prefixes and JSON slash normalization; original text retained externally",
              "files": records}
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    arguments.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "source_files": len(sources), "png_count": report["png_count"],
                      "originals_unchanged": unchanged}))
    return 0 if unchanged else 1


if __name__ == "__main__":
    raise SystemExit(main())
