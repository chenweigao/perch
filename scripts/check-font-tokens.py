#!/usr/bin/env python3
"""Keep interface text sizes on WorkbenchTheme.Typography / ReplyStyle tokens.

ui-spec (正文刻度): views never write a local text size. A numeric literal in
`.system(size: N)` or AppKit `…Font(ofSize: N)` under Sources/ fails unless the
nearest view before it is an `Image` (SF Symbols keep their own optical sizes), or
the line is pinned in scripts/font-exceptions.json (file + stripped line text).
WorkbenchTheme.swift defines the tokens and is exempt. Stale pins fail too.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONT = re.compile(r"\.system\(size:\s*[0-9]|Font\(ofSize:\s*[0-9]")
CTOR = re.compile(r"\b(Image|Text|Label|TextField|Button|Toggle|Menu|Link|SecureField|TextEditor|Picker)\s*[({]")
EXEMPT = {"Sources/AgentWorkbench/WorkbenchTheme.swift"}
LOOKBACK = 3


def is_glyph(lines, i, col):
    """True when the nearest view constructor before the modifier is Image."""
    text, j = lines[i][:col], i
    while True:
        found = list(CTOR.finditer(text))
        if found:
            return found[-1].group(1) == "Image"
        j -= 1
        if j < 0 or i - j > LOOKBACK:
            return False
        text = lines[j]


def main() -> int:
    exceptions = json.loads((ROOT / "scripts/font-exceptions.json").read_text())["exceptions"]
    pins = {(e["file"], e["line"].strip()) for e in exceptions}
    if len(pins) != len(exceptions):
        print("font-exceptions.json: duplicate (file, line) pin")
        return 1
    live = set()
    for path in sorted(ROOT.glob("Sources/**/*.swift")):
        rel = path.relative_to(ROOT).as_posix()
        if rel in EXEMPT:
            continue
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            code = line.split("//", 1)[0]
            if any(not is_glyph(lines, i, m.start()) for m in FONT.finditer(code)):
                live.add((rel, line.strip()))
    errors = [f"literal text size (use WorkbenchTheme.Typography): {f}: {l[:110]}" for f, l in sorted(live - pins)]
    errors += [f"stale font pin (line gone or changed): {f}: {l[:110]}" for f, l in sorted(pins - live)]
    if errors:
        print("\n".join(errors))
        print(f"\n{len(errors)} font check failure(s); see docs/design/ui-spec.md 正文刻度")
        return 1
    print(f"OK: no literal text sizes ({len(pins)} pinned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
