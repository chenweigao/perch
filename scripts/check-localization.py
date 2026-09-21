#!/usr/bin/env python3
"""Localization coverage check for Perch.

The app keeps Simplified Chinese literals as localization keys. This script
verifies that every user-facing Chinese string in the bilingual scope has an
entry in Resources/Localization/en.lproj/Localizable.strings:

1. Every string literal containing CJK in the scoped Swift files (the sidebar
   cluster and the surfaces it opens).
2. Every literal passed to L(...) anywhere under Sources/, regardless of file.

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

# Files whose user-facing literals are covered by the English table. Areas left
# intentionally monolingual for now (composer, transcript, dashboard batch UI,
# previews under Tests/) are not listed here.
SCOPED_FILES = [
    "Sources/AgentWorkbench/SessionSidebar.swift",
    "Sources/AgentWorkbench/WorkspaceSidebarShell.swift",
    "Sources/AgentWorkbench/WorkItemGroupEditor.swift",
    "Sources/AgentWorkbench/TaskGroupPage.swift",
    "Sources/AgentWorkbench/ModelPicker.swift",
    "Sources/AgentWorkbench/ConversationActivityBar.swift",
    "Sources/AgentWorkbench/SessionRowChrome.swift",
    "Sources/AgentWorkbench/RenameSessionSheet.swift",
    "Sources/AgentWorkbench/ConnectionSheets.swift",
    "Sources/AgentWorkbench/LocalAgentSetupSheet.swift",
    "Sources/AgentWorkbench/WorkbenchSettings.swift",
    "Sources/AgentWorkbench/WorkbenchView.swift",
    "Sources/AgentWorkbench/WorkbenchApp.swift",
    "Sources/AgentWorkbench/WorkbenchHeader.swift",
    "Sources/AgentWorkbench/WorkspaceSplitView.swift",
    "Sources/AgentWorkbench/SelectionActions.swift",
    # Core files whose raw values are rendered in the scoped UI via L().
    "Sources/WorkbenchCore/Workspace.swift",
    "Sources/WorkbenchCore/SidebarProjection.swift",
]

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
    return key


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


def scoped_literals() -> dict[str, str]:
    found: dict[str, str] = {}
    for rel in SCOPED_FILES:
        text = (ROOT / rel).read_text(encoding="utf-8")
        for m in LITERAL.finditer(text):
            raw = m.group(1)
            if CJK.search(raw):
                found.setdefault(normalize(raw), f"{rel}")
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
    wanted = scoped_literals() | l_literals()
    missing = sorted(set(wanted) - keys)
    for key in missing:
        print(f"MISSING  {wanted[key]}: {key}")
    unused = sorted(keys - set(wanted))
    for key in unused:
        print(f"unused?  {key}")
    if missing:
        print(f"\n{len(missing)} key(s) missing from {EN_TABLE.relative_to(ROOT)}")
        return 1
    print(f"OK: {len(wanted)} scoped/L() keys covered by en.lproj "
          f"({len(keys)} entries, {len(unused)} without a scoped source)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
