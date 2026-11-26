# Reading canvas

> Current metrics (2026-11-26): 680 pt column, 14 pt default body on a 24 pt line,
> 16 pt entry rhythm; the rules live in [ui-spec 正文刻度](ui-spec.md#正文刻度).

The conversation keeps a centered reading column and the existing native
sidebar/composer glass. All metrics live in `ReplyStyle` (`ReplyMarkdownView.swift`)
on the `ReadingScale` ladder; [the visual refresh](visual-refresh.md) records the
history of the scale.

- Body text follows the reader's setting (14–18 pt, default 14 on a 24 pt line,
  16 pt paragraph separation) in a fixed 680-point column — about 48 CJK characters
  per line at the default. See [ui-spec 正文刻度](ui-spec.md#正文刻度) for the ramp.
- H1, H2 and H3 step up 7, 5 and 4 pt (bold); H4 and below keep the body size
  (semibold). Heading spacing (32 pt above H1–H3, 16 pt above H4–H6, 16 pt below at
  the default) signals hierarchy alongside the ramp.
- Lists, quotes and alerts use compact paragraph gaps. Tables use the secondary
  size (13 pt at the default); code blocks 11 pt on a 19 pt pitch. User messages
  share the body size on a 22 pt line.
- Thoughts: secondary size (13 on 20 at the default), regular, upright, in secondary
  ink; no italic, because PingFang has none and only the Latin glyphs would slant.
  A thought that is still streaming has no row of its own; settled thought headers
  show no elapsed seconds.
- SwiftUI and native cached rows share the same text attributes, block rhythm
  (`ReplyStyle.blockSpacing`), code card, quote and list metrics. A code card's
  horizontal scroller never takes height: the native card overlays it, and the
  SwiftUI card hides it, so a long line does not make a streamed card taller than
  its settled native row when macOS shows legacy scrollers.
- List markers form one right-aligned column per list (at least 10 pt, as wide as the
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
