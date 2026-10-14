# Stream reveal — per-frame pacing of the live reply tail

Ported from ccgui's `stream-reveal.ts` (MIT). The stored reply text is always
complete; a presentation-only cursor paces how much of the tail is on screen.

## Mechanism

- `StreamReveal` (WorkbenchCore) anchors the cursor to the TAIL: a `holdback`
  of received-but-hidden characters drains linearly so everything is visible by
  the 240 ms max-lag deadline. Arrival cadence and rate are measured with an
  EMA, so a provider burst spreads across the frames of its own cadence instead
  of jumping. A backlog over 600 characters is a wholesale dump (session
  switch, window restore), not a stream — it appears at once. A wholesale text
  swap (regeneration) likewise skips animation. A watchdog settles the text if
  frames stall (display asleep), and Reduce Motion bypasses the animation.
- The cursor is published in UTF-16 units of the *cursor space*: the rendered
  paragraph/heading text. Code, list, quote, table and rule blocks are
  zero-length checkpoints that appear whole once the cursor reaches them;
  per-character reveal inside code blocks is a possible follow-up.
- `RevealFrameDriver` (AgentWorkbench) is the shared CVDisplayLink-backed
  clock. It runs only while a drain is pending.
- `ConversationEntryController` owns one reveal per live assistant row
  (`.progress` presentation). It parses the live text once through the existing
  preparation cache and hands the same blocks to the hosted Markdown, so the
  live row still parses once per arrival. The cursor reaches views through
  `\.streamRevealCursor`; `ReplyBlocks` maps it onto groups — completed groups
  stay `.equatable`-equal and only the crossing paragraph group rebuilds per
  frame. When the turn settles (`.progress` → `.message`/`.record`), the
  controller finishes the reveal in the same pass.
- The controller and paragraph groups count the same trailing separators.
  Nested non-text blocks render whole at their checkpoint.

## Verification

Core checks exercise pacing, replacement, completion and Unicode prefixes.
Host lifecycle checks exercise the actual display driver and mount the production
transcript: the growing reply must be visible, its tail initially withheld, then
complete; no callbacks or display link remain after settling. The prior
PerformancePreview throughput numbers did not exercise the hidden live row and
are not acceptance evidence for this feature.

## Boundaries

- Only the live `.progress` row animates; history, settled rows and the native
  settled-message path render complete text immediately.
- The thinking preview keeps its existing append-based viewport.
