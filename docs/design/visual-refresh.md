# Visual refresh: reading scale and sidebar geometry

> Current scale (2026-10-28): every size follows the reader's body size through `ReadingScale`; the default and the rules live in [ui-spec 正文刻度](ui-spec.md#正文刻度). Figures below that differ are history.

Two token sets now own the look of the conversation and the sidebar. Views read
them instead of local numbers, so the SwiftUI and native renderers, and every kind
of sidebar row, cannot drift apart. Tune the look here, not in individual views.

## Reading scale — `ReplyStyle` (`Sources/AgentWorkbench/ReplyMarkdownView.swift`)

The body moved from a web-sized 16/27 pt to the native macOS reading size. The
measure narrows with it, so lines keep a comfortable length.

| Token | Before | Now |
| --- | --- | --- |
| Body / line height | 16 / 27 pt | 14 / 22 pt |
| Paragraph gap (compact: lists, quotes, alerts) | 14 (8) pt | 10 (6) pt |
| H1 / other headings | 18 / 16 pt semibold | 16 / 14 pt semibold |
| Space above / below a heading | 24 / 8 pt | 20 / 6 pt |
| Around a rule; above code and display math | 28; 18 pt | 20; 14 pt |
| Reading column (composer and activity bar follow it) | 720 pt | 680 pt |
| Code text / line spacing | 14 pt / 5 | 12.5 pt / 4 |
| Code card radius, header, text inset | 10, 34, 14 pt | 8, 30, 12 pt |
| Table cells | 14 pt | 13 pt |
| List marker gap, minimum marker column | 9, 18 pt | 8, 16 pt |
| Quote and alert inset (leading / vertical) | 21 / 7 pt | 16 / 4 pt |
| User bubble line, padding, top gap | 24; 14×8; 10 pt | 21; 12×7; 8 pt |
| Gap between entries / within an entry and above actions | 18 / 12 pt | 16 / 10 pt |
| Body ink | label 94 % | label 90 % |
| Thoughts | 13 pt light italic | 13 / 20 pt regular upright, secondary ink |

Thoughts (`ReplyStyle.Process.thoughtSize`, `thoughtLineHeight`) were 12.5 pt
italic until 2026-10-23. Italic slanted only the Latin glyphs, because PingFang has
no italic, so mixed Chinese and English thoughts read unevenly; three cues (smaller,
italic, secondary ink) also made long thoughts hard to read. Size and ink are
enough to set them apart. The streaming preview shows four lines (80 pt), and the
full-text popover is a reading surface of its own: body style, 560 × 360 pt.

`ReplyStyle.blockSpacing(before:after:compact:)` is the single vertical rhythm.
The SwiftUI renderer maps `ReplyBlock`, the native renderer `NativeAssistantBlock`,
to `ReplyStyle.BlockKind` and asks it for the space above each block. Code cards
(`ReplyStyle.Code`), quotes (`ReplyStyle.Quote`) and lists (`ReplyStyle.ListLayout`)
are placed from the same numbers in both renderers.

## Sidebar geometry — `SidebarMetrics` (`Sources/AgentWorkbench/SidebarMetrics.swift`)

Every row shares one icon column and inset. Section titles start at that column.
A project's sessions start under the project's icon, so their titles align with
the project title:

```
| inset 8 | icon 16 | 8 | title …                          |  navigation, pinned and flat sessions
| inset 8 | ▸ 12 | 4 | icon 16 | 8 | project title          |  project header
| inset 8 | indent 16 | icon 16 | 8 | session title          |  session inside a project
```

| Token | Before | Now |
| --- | --- | --- |
| Row height (navigation, sessions, groups) | 34 pt | 32 pt |
| Session row with a status line; disambiguated project | 48; 46 pt | 44 pt |
| Icon column / gap to title | 17 / 8–9 pt | 16 / 8 pt |
| Child indent under a project | 22 pt (misaligned) | 16 pt (icon under icon) |
| Highlight radius | 8 pt | 7 pt |
| Hover / selected / pressed fill | 3 / 6.5 / 9 % | 4.5 / 8 / 11 % |
| Section headers | three styles (11–12 pt, chevron before or after, icon on 置顶) | one: 11 pt semibold at 62 % ink, count, chevron after |

Section headers are darker than secondary text, so 置顶 and the other headers never
read as disabled.

## Secondary text floor

No text is set below 11 pt. On macOS `.caption` and `.caption2` are 10 pt, so
secondary notes, errors and hints use `.subheadline` (11 pt) or an explicit 11 pt
size; tertiary ink only appears on text of at least that size. Sizes of 8–10 pt
remain only for SF Symbols such as chevrons and badges. The 置顶 add button stays a solid control. The native glass
floating sidebar (`WorkspaceSplitView`) and the composer glass retain their adaptive
material; this refresh changes only the inner rows and headers.

## Verification

- `check-host-lifecycle.py` `reading-design` pins the 14/22 pt body and 16 pt H1 in
  both renderers and exports wide/narrow/dark snapshots to `/private/tmp/perch-reading-design`.
- `run-navigation-check.py assistant-rows` / `user-rows` compare native and SwiftUI
  glyph positions and heights at two widths and both appearances, including the
  11-item list and code cards; they now exercise the new scale.
- Native acceptance sidebar layout modes read the row heights from `SidebarMetrics`.
- These are offline fixture checks. They do not certify live sessions, frame rate,
  or how the new sizes look on a particular display. Review the snapshots and the
  sidebar preview (`scripts/build-sidebar-preview.sh`) on the Mac before shipping.
