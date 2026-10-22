#!/usr/bin/env python3
"""Pin numeric corner radii to the scale in docs/UI-RADIUS.md.

Any `cornerRadius: <number>` or `cornerRadius = <number>` literal under Sources/
must be pinned in scripts/radius-exceptions.json (matched by file + stripped line
text). Token references (WorkbenchTheme.Radius.*) need no pin. Stale pins fail too.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PATTERN = re.compile(r"cornerRadius\s*=\s*\d|cornerRadius\s*:\s*(?:CGFloat\s*=\s*)?\d")


def main() -> int:
    exceptions = json.loads((ROOT / "scripts/radius-exceptions.json").read_text())["exceptions"]
    pins = {(e["file"], e["line"].strip()): e for e in exceptions}
    if len(pins) != len(exceptions):
        print("radius-exceptions.json: duplicate (file, line) pin")
        return 1

    live = {}
    for path in sorted(ROOT.glob("Sources/**/*.swift")):
        rel = path.relative_to(ROOT).as_posix()
        for line in path.read_text().splitlines():
            if PATTERN.search(line):
                live.setdefault((rel, line.strip()), []).append(line.strip())

    errors = []
    for key in sorted(set(live) - set(pins)):
        errors.append(f"unpinned radius literal: {key[0]}: {key[1][:100]}")
    for key in sorted(set(pins) - set(live)):
        errors.append(f"stale radius pin (line gone or changed): {key[0]}: {key[1][:100]}")
    if errors:
        print("\n".join(errors))
        print(f"\n{len(errors)} radius check failure(s); see docs/UI-RADIUS.md")
        return 1
    print(f"OK: {len(live)} radius literals pinned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
