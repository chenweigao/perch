#!/usr/bin/env python3
"""Localization coverage check for Perch.

Most localization keys are the Simplified Chinese source text; labels written
in English keep their English text as the key. This script verifies, for every
app and Core source except the acceptance fixtures:

1. Every string literal containing CJK has an entry in
   Resources/Localization/en.lproj/Localizable.strings.
2. Every literal passed to L(...) anywhere under Sources/ has an entry.
3. English text in a lookup position (Text, Button, Label, .help, L(...), ...)
   has an entry whose Chinese value is a translation. Names that read the same
   in both languages, example values and fragments are skipped.

Lines marked `// l10n-ignore` hold data, not UI text, and are skipped. The check
cannot see labels built as String values and shown verbatim; review those.

Interpolation holes `\\(...)` in sources and `%@`/`%lld`/`%f` in the strings
table are all normalized to `<P>` before comparison, for source coverage. Both tables must also have matching keys and preserve
placeholder types and positions; duplicate keys fail the check.

Exits non-zero when a key is missing. Runs anywhere (no macOS required).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EN_TABLE = ROOT / "Resources/Localization/en.lproj/Localizable.strings"
ZH_TABLE = ROOT / "Resources/Localization/zh-Hans.lproj/Localizable.strings"

# Every app and Core source is bilingual. Acceptance fixtures drive synthetic
# sessions that users never see, so they stay monolingual. Previews under Tests/
# are not scanned. A literal that is data rather than UI text (a pattern matched
# against agent output, a protocol value) carries `// l10n-ignore` on its line.
MONOLINGUAL = {
    "Sources/AgentWorkbench/NativeAcceptance.swift",
    "Sources/AgentWorkbench/KimiAcceptance.swift",
    "Sources/AgentWorkbench/InputAcceptance.swift",
    "Sources/AgentWorkbench/AcceptanceSidebarTable.swift",
    "Sources/AgentWorkbench/AcceptanceResponsiveness.swift",
}
SCOPED_FILES = sorted(
    str(path.relative_to(ROOT))
    for folder in ("Sources/AgentWorkbench", "Sources/WorkbenchCore")
    for path in (ROOT / folder).glob("*.swift")
    if str(path.relative_to(ROOT)) not in MONOLINGUAL
)
IGNORE = "l10n-ignore"
# English text in a lookup position needs a Chinese translation. Names and
# notation that read the same in both languages are allowed untranslated.
UI_LITERAL = re.compile(
    r'(?:\b(?:Text|Button|Label|Toggle|Menu|Section|Picker|TextField|SecureField|DisclosureGroup|LabeledContent|Link)\(\s*'
    r'|\.(?:help|accessibilityLabel|accessibilityHint|navigationTitle)\(\s*'
    r'|\bL\(\s*(?:key:\s*)?)"((?:[^"\\]|\\.)*)"')
ENGLISH_WORD = re.compile(r"[A-Za-z]{2,}")
SAME_IN_BOTH = {
    "Agent", "Claude", "Claude Code", "Codex", "DeepSeek", "DSH", "Git", "GitHub", "HEAD", "Herdr", "Kimi",
    "Markdown", "OMP", "OpenAI", "Perch", "Qoder", "Recap", "SSH", "Shell", "macOS", "Mac", "URL", "API", "TeX",
}

CJK = re.compile(r"[一-鿿]")
# A Swift string literal on one line (interpolation contents may nest parens,
# which the literal regex tolerates because it only stops at a quote).
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
# Interpolation hole, tolerating two levels of nested parens (e.g. \(L("…"))).
HOLE = re.compile(r"\\\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)")
# Entry in a .strings file.
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')
FORMAT_SPEC = re.compile(r"%(?:(\d+)\$)?(@|lld|ld|d|f)")
L_CALL = re.compile(r'L\(\s*(?:key:\s*)?"((?:[^"\\]|\\.)*)"')


def normalize(key: str) -> str:
    key = HOLE.sub("<P>", key)
    key = FORMAT_SPEC.sub("<P>", key)
    # A literal percent sign is `%%` in a table key and `%` in source.
    return key.replace("%%", "%")


def format_signature(value: str) -> list[tuple[int, str]]:
    return sorted((int(m.group(1)) if m.group(1) else i, m.group(2))
                  for i, m in enumerate(FORMAT_SPEC.finditer(value.replace("%%", "")), 1))


def table_entries(path: Path) -> dict[str, str]:
    entries = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = ENTRY.match(line)
        if m:
            key, value = m.groups()
            if key in entries:
                raise ValueError(f"{path.name}: duplicate key: {key}")
            if format_signature(key) != format_signature(value):
                raise ValueError(f"{path.name}: placeholder type/order mismatch: {key}")
            entries[key] = value
    return entries


def scoped_lines(rel: str) -> list[str]:
    """Source lines that can carry UI text: comments and ignored data lines are dropped."""
    lines = []
    for line in (ROOT / rel).read_text(encoding="utf-8").splitlines():
        if IGNORE in line or line.lstrip().startswith("//") or line.lstrip().startswith("///"):
            continue
        lines.append(line)
    return lines


def scoped_literals() -> dict[str, str]:
    found: dict[str, str] = {}
    for rel in SCOPED_FILES:
        for line in scoped_lines(rel):
            for m in LITERAL.finditer(line):
                raw = m.group(1)
                if CJK.search(raw):
                    found.setdefault(normalize(raw), f"{rel}")
    return found


def code_like(raw: str) -> bool:
    return bool(re.fullmatch(r"[\w.:/~\-@%+]+", raw)) and bool(re.search(r"[/:~_@]|\w\.\w", raw))


def english_ui_literals() -> dict[str, str]:
    """English literals in lookup positions: they are keys whose Chinese value must be a translation."""
    found: dict[str, str] = {}
    for rel in SCOPED_FILES:
        for line in scoped_lines(rel):
            for m in UI_LITERAL.finditer(line):
                raw = m.group(1)
                words = ENGLISH_WORD.findall(HOLE.sub("", raw))
                if CJK.search(raw) or not words or raw in SAME_IN_BOTH or all(w in SAME_IN_BOTH for w in words):
                    continue
                # A literal nested in an interpolation ends the match early; such a
                # fragment is not a key. Example values (URLs, paths, model ids) are not prose.
                if raw.count("\\(") != len(HOLE.findall(raw)) or code_like(raw):
                    continue
                found.setdefault(normalize(raw), rel)
    return found


def l_literals() -> dict[str, str]:
    found: dict[str, str] = {}
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        calls = list(L_CALL.finditer(text))
        calls += list(re.finditer(r'stateMessage(?:\s*:\s*String.LocalizationValue)?\s*=\s*"((?:[^"\\]|\\.)*)"', text))
        for m in calls:
            raw = m.group(1)
            found.setdefault(normalize(raw), str(path.relative_to(ROOT)))
    return found


def main() -> int:
    try:
        en = table_entries(EN_TABLE)
        zh = table_entries(ZH_TABLE)
        if set(en) != set(zh):
            raise ValueError("English and Chinese tables must contain the same keys")
    except (ValueError, OSError) as error:
        print(error)
        return 1
    keys = {normalize(key) for key in en}
    english = english_ui_literals()
    wanted = scoped_literals() | l_literals() | english
    missing = sorted(set(wanted) - keys)
    for key in missing:
        print(f"MISSING  {wanted[key]}: {key}")
    chinese = {normalize(key): value for key, value in zh.items()}
    untranslated = sorted(key for key in english if key in chinese and not CJK.search(chinese[key]))
    for key in untranslated:
        print(f"NO-ZH    {english[key]}: {key}")
    unused = sorted(keys - set(wanted))
    if "--unused" in sys.argv:
        for key in unused:
            print(f"unused?  {key}")
    if missing or untranslated:
        if missing:
            print(f"\n{len(missing)} key(s) missing from {EN_TABLE.relative_to(ROOT)}")
        if untranslated:
            print(f"{len(untranslated)} English key(s) without a Chinese translation in {ZH_TABLE.relative_to(ROOT)}")
        return 1
    print(f"OK: {len(wanted)} scoped/L() keys covered by en.lproj "
          f"({len(keys)} entries, {len(unused)} without a scoped source)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
