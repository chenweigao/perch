# Native reply reading

Kimi, OMP and Qoder use the same native Markdown renderer. Swift Markdown 0.8.0
parses CommonMark/GFM into `ReplyDocument`; SwiftUI renders the document without
HTML execution or a WebView. Remote image references inside Markdown show their
alt text; dedicated conversation attachments keep their existing renderer.

The reading column and composer share a 700 pt maximum width. Short replies stay
left-aligned within that column. Body text uses the
macOS system font at 14 pt with a 1.625 minimum line-height ratio. H1 uses 16 pt;
H2–H6 stay at the body size. Headings, strong text and table headers use medium
weight, including strong text nested inside a heading or inline code. Headings
have 22 pt of leading space (14 pt in compact lists/quotes) and 7 pt before their
following content; the first block has no leading space. Section spacing carries
the hierarchy without large, heavy titles. List markers use regular weight.
Inline code stays 1 pt smaller than its surrounding text and uses monospace with
no background fill, so tall line fragments do not create gray tiles in prose.
Fenced code retains its separate container; table separators use 6% opacity. Body paragraphs have 12 pt
between them; paragraphs within a list item or quote have 8 pt. Compact block
transitions, such as a paragraph followed by a nested list, have 6 pt of space.
List rows are measured at the available width: adjacent single-line items have
a 2 pt gap, increasing to 6 pt when either item spans multiple lines. Nested list
continuations align with the text, ordered lists preserve their starting number,
and task markers are read-only. Quotes use a fine left rule. Code uses the system
monospace font, a quiet header and horizontal scrolling. Body text, inline paths
and links use native word wrapping, including oversized unbroken tokens, without
inserting characters into selectable text. Text and link colors are unchanged.
Tables render as native grids sized to their viewport, with a 100 pt minimum
text width and 12 pt horizontal padding per cell. Cells wrap within that width;
only tables whose minimum column widths exceed the viewport scroll horizontally.

Copy controls preserve the original reply Markdown or the fenced code content.
Only http, https and mailto Markdown links become clickable. Static text uses
SwiftUI equality to avoid reparsing history on unrelated streaming updates.
Collapsed execution groups instantiate their transcript only when expanded.
The timeline uses stable lazy rows after the native split's intrinsic-size loop
was removed. Historical turns are cached; only visible content is laid out.
Collapsed activity stays uninstantiated; Kimi history is still paged.

## Local visual check

After `scripts/build.sh`, run `scripts/build-reading-preview.sh` and open
`build/Reply Reading Preview.app`. It compiles the actual shared renderer into a
separate fixture app; it never loads saved hosts or contacts remote agents.
`Tests/Fixtures/reply-reading.md` covers Chinese/English prose, nested lists,
non-one starting numbers, tasks, quotes, a table, links and long code. The preview
adds a wide numeric table, a narrow-column toggle and streaming simulation.

`WorkbenchChecks` covers document structure, escaped table pipes, inline styles,
link schemes, unclosed fences and each prefix of a streamed Markdown document.
Visual checks remain separate from protocol checks and remote compatibility.

For a focused typography check, build with `scripts/build.sh`, then run
`scripts/build-reply-typography-preview.sh` and open
`build/Reply Typography Preview.app`. The fixture includes a long H1, H2–H6,
an entirely strong paragraph, mixed Chinese/English, code inside headings,
links, lists and tables. The width picker compares 420, 700 and 760 pt columns;
the window can also be resized. Samples include single- and multi-line list
items, multi-paragraph items, nested lists, long paths/URLs, a three-column table
with long cells, and a seven-column table that scrolls independently.
Inspect it at both normal and narrow window widths:
emphasis should remain distinguishable, headings should wrap without crowding,
and inline code should blend into prose. Check selection and copying separately;
the renderer preserves the original Markdown and parsed document structure.
Copy a wrapped path/URL to check it contains no extra line breaks or invisible
characters, and confirm column alignment and horizontal scrolling in the tables.

## Turn visibility and compact chrome

Assistant progress stays visible in chronological order, interleaved with each
reasoning phase. New reasoning and new overviews append below prior output rather
than replacing a turn-wide slot. Completed reasoning phases have independent
disclosures; the currently streaming phase uses a naturally wrapped viewport that
fits short thoughts and caps its height at 76 pt. The header offers a full-text
popover only when the preview overflows. The viewport follows
new text unless the user scrolls upward, with no flashing scrollbar. Kimi volatile deltas and native
agent snapshots use the same policy. A volatile Kimi message is deduplicated only
against messages in the current turn.

After the turn ends, a text-only answer following the last tool call is treated
as the final reply. Otherwise all assistant process text remains visible under
“过程记录 · 未返回最终回复”. A thinking-only turn opens its thinking record by
default; a tool-only turn shows an explicit no-text notice. These labels never
invent a summary or claim that the requested task succeeded. Runtime notifications
and injected skill context remain separately collapsible at their source positions
instead of becoming user message bubbles.

The system unified compact toolbar holds the session title, directory, status and
stop/menu controls in one line; sync and lifecycle operations live in the session
menu. Native and terminal detail views do not add another header.

Kimi model choices use the server's explicit provider field, not the model ID
prefix (for example `demo-a-proxy` can contain `demo-a/claude-example`). The popover
supports case-insensitive model/provider search and keeps provider identity in the
composer label. A choice applies to the next prompt; opening or searching the
picker does not change the remote session. New Kimi conversations share this
picker. OMP/Qoder retain their existing model configuration; no unverified model
catalog or runtime switching capability is inferred for those adapters.

## Input and floating activity

The shared AppKit composer keeps marked text inside NSTextView until the input
method commits it. SwiftUI refreshes cannot replace an active marked range.
Each conversation owns a stable editor identity and draft binding. Return sends;
Shift-Return adds a newline; candidate-confirmation Return stays with the input
method. The editor grows from 40 to 180 pt and then scrolls internally.

Kimi supports file selection, file drop, file/image paste, attachment thumbnails
and attachment-only prompts. Upload still uses the existing Kimi multipart API;
OMP/Qoder attachments are not inferred from that capability.

The plain-text input advertises file URL, PNG and TIFF pasteboard types only when
an attachment handler is connected. AppKit can therefore enable its standard Paste
command for an image-only clipboard; the native `readSelection(from:type:)` path
converts image data into a PNG attachment without replacing the text draft.
`scripts/check-composer.sh` checks PNG/TIFF type negotiation and file URLs using
private pasteboards. On macOS, also copy a screenshot and press ⌘V in a loaded
Kimi conversation (and use Edit → Paste): confirm one thumbnail appears and the
existing draft remains. Send it to verify upload separately. OMP/Qoder text-only
inputs do not advertise image paste support.

Streaming thinking uses complete light italic text in a fixed 76 pt vertical scroll area.
It wraps to the reading width instead of truncating a 240-character suffix; text
updates do not move the outer transcript. Its inner viewport follows new text by
default, pauses when the user scrolls upward, and resumes after they return to the
bottom. The activity
bar stays above the composer, showing a quiet three-dot opacity pulse while busy,
paused under Reduce Motion. Approval/question waits do not animate as active work.
The Kimi TodoList schema was checked against installed Kimi 2.0.2 source: successful
`TodoList` calls replace `todos: [{title, status}]`, where status is `pending`,
`in_progress` or `done`; missing todos means query and an empty array clears.
The bar displays progress and the current task, with a popover for the full list.
It does not infer a plan from prose or guess other agents' tool schemas.
The floating list is scoped to the latest real user turn; injected runtime context
does not start a new turn. A fully completed list remains while the turn is running
and disappears when it ends. Incomplete lists remain marked “未完成” while paused
or ended. Starting a new user turn clears the old floating list until the agent
successfully writes a new plan. Historical tool records are never removed.

User-initiated upward scrolling pauses automatic following. A centered down-arrow
appears only while away from the bottom; clicking it resumes following. AppKit's
[didLiveScrollNotification](https://developer.apple.com/documentation/appkit/nsscrollview/didlivescrollnotification)
distinguishes user scrolling from programmatic stream updates.

The sidebar uses native NSSplitViewController with a saved width between 220 and 420 pt.
Floating controls use the public macOS 26
[Liquid Glass modifier](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views),
which is available in the installed SDK. macOS 14/15 use system Material; the
transcript and composer retain solid reading surfaces.

`scripts/check-composer.sh` runs actual AppKit marked-text, Unicode, Return and
draft synchronization checks. `scripts/build-composer-preview.sh` builds an
isolated input window with a 100 ms refresh, two drafts and local-only submissions.

The native workspace split extends under the unified titlebar. AppKit owns the
glass sidebar's toolbar avoidance; the outer SwiftUI view does not duplicate that
top inset. No fixed negative offsets or manual titlebar padding are added.

## Independent transcript channels

Tool summaries remain visible in source order alongside public progress and
individual thinking phases, including after completion. Only tool arguments,
progress and output fold inside each tool row; there is no outer execution group.
Tool-call IDs preserve row identity across live/history handoff. Runtime context
has its own disclosure.
Only the latest phase can show “思考中”; prior reasoning collapses to “思考记录”.
Source message and part offset identify each row, independent of its live/completed
presentation. Repeated thinking/text parts within one message therefore stay unique,
and completing a turn does not recreate its rows. Thinking-only turns retain the
readable fallback and never invent a final summary.

The composer reuses the shared native macOS 26 regular glass surface (system material
on older macOS; opaque system background with Reduce Transparency). No extra white
card, custom border or shadow is layered underneath. Keyboard shortcuts stay in the
send-button tooltip rather than occupying a permanent footer. Sidebar primary text
uses the system font at 13pt, secondary text at 11pt; the app title remains 16pt.
AppKit's spinning progress indicator supplies visible motion in the activity bar and
running sidebar rows without a SwiftUI animation timer. Reduce Motion shows a static
hourglass; sidebar attention/review/idle states also have distinct visual indicators.

The turn activity popover anchors to the pointer position within the task-bar button,
held still while open. Keyboard/accessibility activation without a pointer uses
the button bounds, and AppKit keeps the popover within screen bounds.

The bar uses the active tool's description when available, otherwise a localized
operation label. Approval, disconnection and stopping states take precedence over
tool descriptions. Pending input shows its count and a direct review button;
attention colors apply to the status and action, leaving elapsed time neutral.
Details show tools needing attention, current operations and then the plan. An
absent plan has no placeholder; a turn without tools shows its current status.

The activity clock belongs to the connection and is keyed by session and turn;
switching views does not restart it. A request submitted by this client displays
elapsed time from submission until the client receives its ending state, including
transport, tool calls and waits. A turn discovered midway displays observed time
instead. Completed clocks remain fixed, and a new turn replaces the previous one.
The expanded view estimates processing and input-wait intervals from received
status updates; these are client wall times, not model-only execution measurements.
An app restart loses the local observation history and starts an observed clock.


## Scroll layout contract

The scroll view directly owns one LazyVStack. `ConversationTranscript` supplies its
rows without another layout container; parent views also place pagination, live tools,
interaction cards and the bottom marker in that same stack. A nested eager parent
around the lazy transcript can lose viewport geometry for unusually tall messages.
Selectable transcript text uses AppKit NSTextView with explicit attributed fonts,
links, colors and paragraph metrics. There is no SwiftUI text-selection overlay.
Sizing probes use an independent attributed-string measurement, cache by width and
invalidate on content changes. They must not mutate the live text container.
The reading fixture checks Chinese wrapping, remeasurement after a zero-width Grid
probe, unchanged drawing geometry, and streaming height invalidation at startup.
List baselines and secondary quote colors are supplied explicitly across the bridge.

The reading fixture includes **富文本历史**:20 turns, a very tall first message,
Chinese paragraphs, mixed fonts, lists, tables, code and links; prepend twice for60
turns. Build a local read-only replay with
`READING_SNAPSHOT=/absolute/path/to/snapshot.json scripts/build-reading-preview.sh`.
The optional **本地快照** scene uses no API or transport; the private snapshot is copied
only into ignored build output. A normal fixture build removes that optional resource.
