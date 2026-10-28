# Reading canvas

The conversation keeps a centered reading column and the existing native
sidebar/composer glass. All metrics live in `ReplyStyle` (`ReplyMarkdownView.swift`);
see [the visual refresh](visual-refresh.md) for the complete scale and rationale.

- Body text follows the reader's setting (14–18 pt, default 16 on a 26 pt line,
  12 pt paragraph separation) in a fixed 680-point column — about 42 CJK characters
  per line at the default. See [ui-spec 正文刻度](ui-spec.md#正文刻度) for the ramp.
- H1 and H2 step up 4 and 2 pt; H3 and below keep the body size. Heading spacing
  (20 pt above, 6 pt below at the default), rather than a large type-size ladder,
  signals hierarchy.
- Lists, quotes and alerts use compact paragraph gaps. Code and tables use the
  secondary size (14 pt at the default). User messages share the body size and line.
- Thoughts: secondary size (14 on 22 at the default), regular, upright, in secondary
  ink; no italic, because PingFang has none and only the Latin glyphs would slant.
  A thought that is still streaming has no row of its own; once settled its
  header reads 已思考 N秒 when this app watched it.
- SwiftUI and native cached rows share the same text attributes, block rhythm
  (`ReplyStyle.blockSpacing`), code card, quote and list metrics. A code card's
  horizontal scroller never takes height: the native card overlays it, and the
  SwiftUI card hides it, so a long line does not make a streamed card taller than
  its settled native row when macOS shows legacy scrollers.
- List markers form one right-aligned column per list (at least 16 pt, as wide as the
  widest marker), computed by `ReplyListMetrics` for both renderers. Items of a ten-item
  ordered list start at one x, and a streamed reply does not shift when it settles into
  the native row. Strong text never lightens a semibold heading.
- One entry is one selection, even though its paragraphs, headings, list items and
  code blocks are separate text views (`ReplySelection`).
  - A drag continues across them, and ⌘A selects the whole entry.
  - Copy, Quote and the selection bar read the whole span. A click elsewhere ends
    it, so no stale selection is left behind.
  - The reply's context menu also offers 复制整条回复（纯文本）, which copies the reply
    without Markdown syntax (`ReplyPlainText`).
- The selection bar appears once a selection settles: after the mouse button is
  released, or briefly after a keyboard change. It is built once and then only
  moved, fades in, and steps aside while the transcript scrolls rather than
  trailing it. Covered by the host check `reply-selection`.

Return to latest floats at the bottom center of the transcript, 8 points above the
input-area activity controls. Only the small button has a glass surface; its
surroundings remain transparent. It reserves no footer space, and showing/hiding
it or changing its label does not resize the reading viewport.
While reading history it shows an arrow, expanding to “New content” when the
conversation revision changes. Clicking restores the existing follow-tail state;
new content alone does not move the reader. Kimi and native agents share this layout.

Acceptance uses production native components: heading/body attributes, expanded
process access, text selection, wide/narrow return-button clicks, actual tail
navigation and stable viewport geometry. Existing navigation checks cover glyph
parity between native/fallback paragraphs, user rows and assistant rows. These are
offline functional checks, not claims of measured performance or live model quality.
