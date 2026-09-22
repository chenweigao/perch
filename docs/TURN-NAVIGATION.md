# Conversation turn navigation

The left edge of each native/Kimi transcript shows a compact index of loaded
user turns. Hover to read the question and latest response excerpt; click to
jump to the question. Up/Down and accessibility increment/decrement move one
turn at a time. Escape dismisses keyboard focus. The dark tick tracks the turn
at the top of the reading viewport.

The rail is hidden for zero or one turn. Dense histories share painted ticks,
while pointer position and keyboard movement still address individual turns.
Kimi's existing **Load earlier messages** button expands the indexed history;
the rail does not fetch remote history on hover.

## Rendering contract

- Excerpts are bounded plain text cached by `ConversationProjection` alongside
  each turn. Thinking, tool output, and runtime context are excluded.
- Hover state lives only in the rail. It does not mount or measure transcript
  rows, parse Markdown, or call a provider.
- The native document maps stable entry IDs to its existing virtual geometry.
  Selecting a turn pauses follow mode and directly reveals its row. Existing
  Return-to-latest behavior resumes following.
- Current-turn updates use the coalesced viewport pass and a binary lookup of
  turn starts. Immutable rail inputs keep outgoing views safe when a session
  is replaced or cleared.

## Checks

Build the application with `scripts/build.sh`, then run `WorkbenchChecks` and
`ConnectionChecks`. On the Mac with mixed Command Line Tools interfaces, first
use the existing `scripts/prepare-local-swiftpm.sh` and its printed environment
variable.

```sh
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py turns --output .local/turn-check --switches 2
python3 scripts/run-navigation-check.py search --output .local/turn-search --switches 2
python3 scripts/run-navigation-check.py anchor --output .local/turn-prepend --switches 2
```

The `turns` fixture uses 200 mixed-content turns and checks cold jumps in both
directions, exact question alignment, bounded retained hosts, streaming while
reading history, history prepend, session replacement, and clearing the
conversation. Its layout timings exclude hardware input and compositor
presentation; they are not a frame-rate or Codex performance comparison.

### Local verification, 2026-09-22

On macOS 26.6.2, the release app build/signature, WorkbenchChecks,
ConnectionChecks, localization and publication checks passed. The three native
fixture modes above passed on the rebased implementation (`25a46e6`, based on
`21f03a3`). The six cold jumps took 31–84 ms for synchronous application
layout/display work and retained only 1–7 row hosts. There is no claim of
continuous 60 fps for first-time complex Markdown layout.

Reports are in `.local/turn-navigation-verified`, `.local/search-verified`, and
`.local/prepend-verified`. Live SSH validation was skipped because
`WORKBENCH_LIVE_HOST` was unset. Native fixture results do not certify a real
remote-provider session.
