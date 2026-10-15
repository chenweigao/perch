#!/usr/bin/env python3
"""Static check that every preview build script compiles the sources it needs.

Preview apps (scripts/build-*-preview.sh) pass swiftc an explicit list of app
sources. When a listed file starts using a type, environment key or view
modifier declared in another file, the preview stops compiling, and nothing
that runs in CI notices. This approximates Swift name resolution:

- Visible declarations in Sources/AgentWorkbench: non-private top-level types,
  functions and constants; `View` extension functions (used as `.name(`); and
  `EnvironmentValues` extension properties (used as `\\.name`).
- A preview needs the declaring file when a compiled file uses that name and no
  compiled file declares it. Test doubles in the preview's own files count.
- Code in inactive `#if` blocks is ignored, using the script's `-D` flags.
- Importing SwiftMath requires linking its objects and copying its font bundle.
  Importing GhosttyTerminal requires linking its objects.

Scripts that compile every app source (`ls Sources/AgentWorkbench/*.swift`)
only get the link checks. Runs anywhere; no macOS required.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources/AgentWorkbench"

MODIFIERS = r"(?:(?:public|internal|package|final|open|nonisolated|indirect|static|class|override|mutating|lazy|weak|unowned|dynamic|required|convenience)\s+)*"
ATTRIBUTES = r"(?:@[\w.]+(?:\([^()]*\))?\s+)*"
DECLARATION = re.compile(r"^" + ATTRIBUTES + MODIFIERS + r"(struct|class|enum|protocol|actor|typealias|func|let|var)\s+([A-Za-z_]\w*)")
EXTENSION = re.compile(r"^" + ATTRIBUTES + r"(?:(public|internal|private|fileprivate)\s+)?extension\s+([\w.]+)")
MEMBER = re.compile(r"^    " + ATTRIBUTES + MODIFIERS + r"(func|var|let)\s+([A-Za-z_]\w*)")
PRIVATE = re.compile(r"^\s*" + ATTRIBUTES + r"(?:\w+\s+)*?(private|fileprivate)\b")
IDENTIFIER = re.compile(r"[A-Za-z_]\w*")
KINDS = ("name", "modifier", "key", "member")
LIBRARIES = {"SwiftMath": ["SwiftMath", "SwiftMath_SwiftMath.bundle"], "GhosttyTerminal": ["GhosttyTerminal"]}


def strip_strings_and_comments(text: str) -> str:
    """Blank out comments and string literal contents, keeping line structure."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * text.count("\n", i, j))
            i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append('""' + "\n" * text.count("\n", i, j))
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            out.append('""')
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def active_lines(text: str, flags: set[str]) -> list[str]:
    """Drop lines inside inactive #if/#elseif/#else branches."""
    def holds(condition: str) -> bool:
        condition = condition.strip()
        if condition.startswith("!"):
            return not holds(condition[1:])
        if "||" in condition:
            return any(holds(part) for part in condition.split("||"))
        if "&&" in condition:
            return all(holds(part) for part in condition.split("&&"))
        if condition.startswith("os(") or condition.startswith("canImport("):
            return "macOS" in condition or "AppKit" in condition or "SwiftUI" in condition
        return condition.strip("() ") in flags
    lines, stack = [], []  # stack entries: [this branch active, some branch taken]
    for line in text.splitlines():
        directive = line.strip()
        if directive.startswith("#if "):
            parent = all(entry[0] for entry in stack)
            taken = parent and holds(directive[4:])
            stack.append([taken, taken])
        elif directive.startswith("#elseif ") and stack:
            parent = all(entry[0] for entry in stack[:-1])
            taken = parent and not stack[-1][1] and holds(directive[8:])
            stack[-1] = [taken, stack[-1][1] or taken]
        elif directive.startswith("#else") and stack:
            parent = all(entry[0] for entry in stack[:-1])
            stack[-1] = [parent and not stack[-1][1], True]
        elif directive.startswith("#endif") and stack:
            stack.pop()
        elif all(entry[0] for entry in stack):
            lines.append(line)
            continue
        lines.append("")
    return lines


class Source:
    def __init__(self, path: Path, flags: set[str]):
        self.path = path
        self.lines = active_lines(strip_strings_and_comments(path.read_text(encoding="utf-8")), flags)
        # Each kind of use resolves in its own namespace: a stored property named
        # like an environment key does not provide that key. Members of other
        # extensions are keyed "Type.member".
        self.declared = {kind: set() for kind in KINDS}  # any visibility
        self.provides = {kind: set() for kind in KINDS}  # visible to other files
        extension, hidden = None, False
        for line in self.lines:
            if extension is not None and line.startswith("}"):
                extension = None
                continue
            match = EXTENSION.match(line)
            if match:
                hidden, extension = match.group(1) in ("private", "fileprivate"), match.group(2)
                continue
            if extension is not None:
                member = MEMBER.match(line)
                if member:
                    if extension == "View" and member.group(1) == "func":
                        kind, key = "modifier", member.group(2)
                    elif extension == "EnvironmentValues" and member.group(1) == "var":
                        kind, key = "key", member.group(2)
                    else:
                        kind, key = "member", extension + "." + member.group(2)
                    self.declared[kind].add(key)
                    if not hidden and not PRIVATE.match(line):
                        self.provides[kind].add(key)
                continue
            match = DECLARATION.match(line)
            if match:
                self.declared["name"].add(match.group(2))
                if not PRIVATE.match(line):
                    self.provides["name"].add(match.group(2))
            elif line[:1].isspace():
                nested = re.match(r"^\s+" + ATTRIBUTES + r"(?:\w+\s+)*(struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)", line)
                if nested:
                    self.declared["name"].add(nested.group(2))
        body = "\n".join(self.lines)
        self.tokens = set(IDENTIFIER.findall(body))
        self.dotted = set(re.findall(r"\.([A-Za-z_]\w*)", body))
        self.used_modifiers = set(re.findall(r"\.([A-Za-z_]\w*)\s*\(", body))
        self.used_keys = set(re.findall(r"\\\.([A-Za-z_]\w*)", body))
        self.imports = set(re.findall(r"^import\s+(\w+)", body, re.M))

    def uses_member(self, key: str) -> bool:
        """`Type.member` from an extension on a type the app does not declare: the
        member is read with a dot, and the type is named here (notification names
        are read as `.name` without naming the type)."""
        owner, member = key.rsplit(".", 1)
        return member in self.dotted and (owner == "Notification.Name" or owner.split(".")[-1] in self.tokens)


def compiled_files(script: str) -> tuple[list[Path], list[Path], bool]:
    whole = bool(re.search(r"ls\s+Sources/AgentWorkbench/\*\.swift", script))
    if whole:
        excluded = set(re.findall(r"grep -v\s+(\w+)\.swift", script))
        app = sorted(p for p in APP.glob("*.swift") if p.stem not in excluded)
    else:
        names = set(re.findall(r"Sources/AgentWorkbench/(\w+)\.swift", script))
        # `for name in A B; do ... Sources/AgentWorkbench/${name}.swift ... done`
        for variable, words, body in re.findall(r"for\s+(\w+)\s+in\s+([\w ]+);\s*do(.*?)\bdone\b", script, re.S):
            if re.search(r"Sources/AgentWorkbench/\$\{?" + variable + r"\}?\.swift", body):
                names.update(words.split())
        app = sorted({APP / f"{name}.swift" for name in names})
    tests = sorted({ROOT / "Tests" / folder / f"{name}.swift"
                    for folder, name in re.findall(r"Tests/(\w+)/(\w+)\.swift", script)})
    return app, tests, whole


def check(script_path: Path) -> list[str]:
    script = script_path.read_text(encoding="utf-8")
    if "swiftc" not in script:
        return []  # wraps another preview build
    flags = set(re.findall(r"-D\s+(\w+)", script))
    app, tests, whole = compiled_files(script)
    every = {path: Source(path, flags) for path in sorted(APP.glob("*.swift"))}
    sources = [every[path] if path in every else Source(path, flags) for path in app]
    sources += [Source(path, flags) for path in tests if path.exists()]
    problems = [f"missing file {path.relative_to(ROOT)}" for path in app + tests if not path.exists()]
    app_types = set().union(*(s.declared["name"] for s in every.values()))
    providers: dict[tuple[str, str], set[Path]] = {}
    for path, source in every.items():
        for kind, names in source.provides.items():
            for name in names:
                # Extensions of the app's own types travel with those types.
                if kind == "member" and name.split(".")[0] in app_types:
                    continue
                providers.setdefault((kind, name), set()).add(path)
    members = [name for kind, name in providers if kind == "member"]
    if not whole:
        compiled = {source.path for source in sources}
        added: dict[Path, set[str]] = {}
        while True:
            declared = {kind: set().union(*(s.declared[kind] for s in sources)) for kind in KINDS}
            needed: dict[Path, set[str]] = {}
            for source in sources:
                wants = [("name", t) for t in source.tokens] + [("modifier", m) for m in source.used_modifiers] \
                    + [("key", k) for k in source.used_keys] + [("member", m) for m in members if source.uses_member(m)]
                for kind, name in wants:
                    if name in declared[kind]:
                        continue
                    for provider in providers.get((kind, name), ()):
                        if provider not in compiled:
                            needed.setdefault(provider, set()).add(name)
            if not needed:
                break
            for provider, names in needed.items():
                added.setdefault(provider, set()).update(names)
                compiled.add(provider)
                sources.append(every[provider])
        for provider, names in sorted(added.items()):
            problems.append(f"add {provider.relative_to(ROOT)} (uses {', '.join(sorted(names)[:4])})")
    # A preview's own declarations must not redeclare compiled app declarations.
    app_sources = [s for s in sources if s.path.parent == APP]
    for test in (s for s in sources if s.path.parent != APP):
        for app_source in app_sources:
            for name in sorted(test.provides["name"] & app_source.provides["name"]):
                problems.append(f"{test.path.relative_to(ROOT)} redeclares {name} from {app_source.path.relative_to(ROOT)}")
    imports = set().union(*(s.imports for s in sources)) if sources else set()
    for library, markers in LIBRARIES.items():
        if library in imports:
            problems += [f"{library} is imported but the script never mentions {marker}" for marker in markers if marker not in script]
    return problems


def main() -> int:
    scripts = sorted((ROOT / "scripts").glob("build-*-preview.sh"))
    failures = 0
    for script in scripts:
        problems = check(script)
        if problems:
            failures += 1
            print(f"{script.relative_to(ROOT)}:")
            for problem in problems:
                print(f"  - {problem}")
    if failures:
        print(f"{failures} of {len(scripts)} preview scripts do not compile the sources they need.")
        return 1
    print(f"OK: {len(scripts)} preview scripts compile the sources they need.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
