import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def redact_text(text):
    text = re.sub(r"/Users/(?!Shared(?:/|$))[^/\s\"']+", "/Users/developer", text)
    return re.sub(r"/home/[^/\s\"']+", "/home/developer", text)


def normalize_json(value):
    if isinstance(value, str):
        return redact_text(value)
    if isinstance(value, list):
        return [normalize_json(item) for item in value]
    if isinstance(value, dict):
        return {key: normalize_json(item) for key, item in value.items()}
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    source, destination = arguments.source.resolve(), arguments.destination.resolve()
    if destination.exists() or arguments.output.exists() or source in destination.parents:
        raise ValueError("Refusing to overwrite evidence or publish into its source")
    paths = sorted(path for path in source.rglob("*") if path.is_file())
    if any(path.is_symlink() for path in source.rglob("*")):
        raise ValueError("Publication input must contain only regular files/directories")
    originals = {str(path.relative_to(source)): digest(path) for path in paths}
    destination.mkdir(parents=True)
    records = []
    for path in paths:
        relative = path.relative_to(source)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        content = path.read_bytes()
        png = path.suffix.lower() == ".png"
        if png:
            if not content.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError(f"Invalid PNG input: {relative}")
        else:
            try:
                text = content.decode("utf-8")
            except UnicodeDecodeError:
                text = None
            if text is not None:
                if path.suffix == ".json":
                    published = json.dumps(normalize_json(json.loads(text)), ensure_ascii=False, indent=2) + "\n"
                else:
                    published = redact_text(text)
                target.write_text(published)
        if png and target.read_bytes() != content:
            raise ValueError(f"PNG bytes changed during publication: {relative}")
        records.append({"file": str(relative), "source_sha256": originals[str(relative)],
                        "published_sha256": digest(target), "png_bytes_preserved": png})
    if any(digest(source / relative) != expected for relative, expected in originals.items()):
        raise ValueError("Original evidence changed during publication")
    report = {"status": "passed", "files": records, "source_files": len(paths),
              "png_count": sum(record["png_bytes_preserved"] for record in records),
              "originals_unchanged": True,
              "text_policy": "Only machine home prefixes and JSON slash normalization; original text retained externally"}
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "files"}, ensure_ascii=False))


if __name__ == "__main__":
    main()
