# Reading canvas

The conversation keeps a centered reading column and the existing native
sidebar/composer glass. All metrics live in `ReplyStyle` (`ReplyMarkdownView.swift`);
see [the visual refresh](visual-refresh.md) for the complete scale and rationale.

- System body text: 14 pt on a 22 pt line with 10 pt paragraph separation, in a
  680-point column (about 48 CJK characters per line). 16 pt read as web-sized in a
  native window.
- Ordinary Markdown headings: 14 pt semibold; H1: 16 pt. All use the same 22 pt
  line height. Heading spacing (20 pt above, 6 pt below), rather than a large
  type-size ladder, signals hierarchy.
- Lists, quotes and alerts use compact 6 pt paragraph gaps. Code uses 12.5 pt
  monospaced text and tables 13 pt. User messages share the body size on a slightly
  tighter 21 pt line.
- SwiftUI and native cached rows share the same text attributes, block rhythm
  (`ReplyStyle.blockSpacing`), code card, quote and list metrics. A code card's
  horizontal scroller never takes height: the native card overlays it, and the
  SwiftUI card hides it, so a long line does not make a streamed card taller than
  its settled native row when macOS shows legacy scrollers.
- List markers form one right-aligned column per list (at least 16 pt, as wide as the
  widest marker), computed by `ReplyListMetrics` for both renderers. Items of a ten-item
  ordered list start at one x, and a streamed reply does not shift when it settles into
  the native row. Strong text never lightens a semibold heading.

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
