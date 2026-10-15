# Sidebar localization review

The initial bilingual sidebar change had three functional gaps:

- `String(localized:locale:)` formatted for a locale but still used the launch-language resource bundle. A competing `String` overload also erased interpolation keys, leaving counts and destructive-action confirmations untranslated. Lookup now chooses the lproj explicitly and labels dynamic keys with `L(key:)`.
- AppKit's four hosting roots did not inherit the window locale. The split view now passes it to each root without changing view identity. Dynamic labels use the same environment via `UILocalization`, rather than reading a stale preference during a SwiftUI update. Toolbar labels and app commands are covered too.
- Cached session descriptions and connection status strings retained their old language. A preference change refreshes presentation data only; it does not recreate connections, restore sessions, send prompts, or update task-event state. Connection labels retain their localization value and format at display time.

The two resource tables now have identical key sets; the checker rejects duplicate keys and placeholder type/order changes. System language selection uses language preferences rather than region formats. Switching back to System removes the app-specific AppleLanguages override. Standard macOS menu chrome may follow the new language after relaunch.

Scope was first the sidebar, its settings/sheets, related header and app commands. Since 2026-10-15 it covers the whole app: transcript and tool cards, find bar, composer and queue, file panel, dashboard batch actions, connection and archive messages, and the Core strings they show. Acceptance fixtures stay monolingual. Agent-provided content is never translated.

`check-localization.py` now scans every app and Core source. Chinese literals need an English entry, and English text in a lookup position needs a Chinese translation. Lines that hold data rather than UI text (agent-output patterns, protocol values, example placeholders) carry `// l10n-ignore`. The checker cannot see labels built as `String` and shown verbatim (`Text(string)`, `.help(string)`), so those are fixed in review: pass `L(…)` or a `LocalizedStringKey`. Labels written in English keep their English text as the key, so preview apps without lproj still read the same text.

## Checks

```sh
python3 scripts/check-localization.py
python3 -m unittest discover -s Tests/Localization -p 'test_*.py'
bash scripts/check-localization-runtime.sh
swift run -c release WorkbenchChecks
bash scripts/build-localization-preview.sh
```

The runtime checker has its own bundle/preferences and tests en → zh-Hans → en, dynamic keys, integer/string interpolation and System selection. The offline preview uses the production AppKit split view, an equatable parent and a counter to verify that switching languages updates all roots while retaining local state. Neither connects remote agents or loads production sessions.

Observed in the offline preview: English → Chinese → English updates navigation, untitled-session text, approval status, environment count, header and toolbar. The counter remains at 1 throughout, demonstrating that the content root was not recreated.

The review branch also incorporates main at `7c88209`; the sidebar conflict was resolved by retaining its larger filter target/alignment and the translated filter label. The native toolbar button alignment is preserved, and its tooltips/accessibility labels refresh with the selected language. The integrated Release app passed WorkbenchChecks, ConnectionChecks, catalog coverage and signature verification. The additional ComposerChecks process was terminated with SIGKILL twice (including after ad-hoc re-signing); its cause is unconfirmed and this check is not counted as passing. No live agent prompts were sent for acceptance.
