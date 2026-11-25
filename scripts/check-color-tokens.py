#!/usr/bin/env python3
"""Keep status colors on the semantic tokens in WorkbenchTheme.Status.

Raw `.orange` / `.red` / `.green` / `.blue` / `.yellow` (SwiftUI implicit members,
`Color.x`, or `NSColor.systemX`) under Sources/ must be pinned in
scripts/color-exceptions.json (matched by file + stripped line text), with a reason:
identity palettes, search highlights and alert kinds are not statuses. Status
meaning goes through WorkbenchTheme.Status (attention / danger / success / unread),
whose light values keep text contrast on white. WorkbenchTheme.swift defines the
tokens and is exempt. Stale pins fail too. See docs/design/ui-spec.md (颜色).
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HUES = r"(?:orange|red|green|blue|yellow)"
PATTERN = re.compile(
    rf"\bColor\.{HUES}\b|\.system(?:Orange|Red|Green|Blue|Yellow)\b|(?<=[\s(:?,\[])\.{HUES}\b(?!\w)")
EXEMPT = {"Sources/AgentWorkbench/WorkbenchTheme.swift"}


def strip_comment(line: str) -> str:
    code = line.split("//", 1)[0]
    return re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)


def main() -> int:
    exceptions = json.loads((ROOT / "scripts/color-exceptions.json").read_text())["exceptions"]
    pins = {(e["file"], e["line"].strip()): e for e in exceptions}
    if len(pins) != len(exceptions):
        print("color-exceptions.json: duplicate (file, line) pin")
        return 1
    live = set()
    for path in sorted(ROOT.glob("Sources/**/*.swift")):
        rel = path.relative_to(ROOT).as_posix()
        if rel in EXEMPT:
            continue
        for line in path.read_text().splitlines():
            if PATTERN.search(strip_comment(line)):
                live.add((rel, line.strip()))
    errors = [f"raw status color (use WorkbenchTheme.Status): {f}: {l[:110]}" for f, l in sorted(live - set(pins))]
    errors += [f"stale color pin (line gone or changed): {f}: {l[:110]}" for f, l in sorted(set(pins) - live)]
    if errors:
        print("\n".join(errors))
        print(f"\n{len(errors)} color check failure(s); see WorkbenchTheme.Status")
        return 1
    print(f"OK: {len(live)} raw color literals pinned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
