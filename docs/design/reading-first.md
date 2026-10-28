# Reading-first conversation body

The reply is the primary reading surface. Process is available without dominating the page.

- Shared native/SwiftUI typography from one `ReadingScale` (see [ui-spec 正文刻度](ui-spec.md#正文刻度)); narrow windows wrap the same content. Dynamic system colors preserve dark mode.
- User prompts retain their existing bubble, actions and full content. Code retains its language label, copy button, gutter and horizontal scrolling. No new global text cache or syntax engine.
- Completed thoughts, intermediate commentary and successful tools share a clear “Thoughts and tools” disclosure with a count. The open group uses a simple leading rule. Expansion remains scoped to the conversation and row.
- A thought that is still streaming has no transcript row; the activity bar communicates the live phase. Settled thoughts read 已思考 N秒 when this app watched them. Successful single-tool stages now use the same disclosure as larger stages. Running, failed, pending and uncertain tools stay visible.
- Existing copy/quote/regenerate, file links, search-to-fold navigation, bookmarks, turn navigation and manual scroll-follow intent remain connected to their current handlers. Sidebar and composer glass remain unchanged.

## Verification

Signed native checks cover wide/narrow and light/dark windows, full code text, selectable reply content, matching native/fallback heading metrics, actual mouse clicks to expand/read/collapse process, plus exported window images. Core checks protect attention visibility and preserve folded source content/order. Navigation reading and interaction fixtures exercise the existing rendering/selection paths. These are local synthetic interaction checks, not a live model session or an FPS measurement.

The upstream comparison and rejected cache experiment are recorded in `../reviews/ccgui-followup.md`.
