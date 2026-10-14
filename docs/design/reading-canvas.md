# Reading canvas

The conversation keeps its centered 720-point reading column and existing native
sidebar/composer glass. Typography now emphasizes a consistent reading rhythm:

- System body text: 16 pt with a 27 pt line height and 14 pt paragraph separation.
- Ordinary Markdown headings: 16 pt semibold; H1: 18 pt. All use the same 27 pt
  line height. Heading spacing, rather than a large type-size ladder, signals hierarchy.
- Lists retain tighter inner spacing. Code and table text use 14 pt. User messages
  share the body size with a slightly tighter 24 pt line height.
- SwiftUI and native cached rows share the same text attributes and spacing.

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
