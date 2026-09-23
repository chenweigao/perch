# Real Kimi transcript scrolling — 2026-09-23

The real Perch app was exercised against the user's completed Kimi conversation
on `agent-env`. No preview or fixture was used for the conversation acceptance.
The reported symptoms are continuous stutter and content moving unexpectedly
while scrolling. The change below addresses the observed anchor defect;
smooth frame delivery is not established.

## Runtime identity

All observed bundles advertise `0.1.0 (1)`, so that version alone is insufficient.

| Capture | PID | Executable SHA-256 prefix | Provenance |
| --- | --- | --- | --- |
| Original installed app | 74157 | `0f0c22858f0e` | Matches the primary checkout's existing build; checkout HEAD was `c27acd4`, but no Git revision is embedded in that app. |
| Replaced by another task during capture | 8492 | `4384261721b1` | Matches the other task's `dc06ab9` workbench-layout build. The user paused further replacements. |
| Repeated installed baseline | 33630 | `4384261721b1` | Same installed executable, restarted for matched history loading. |
| Final local release | 52203 | `b793210a18e6` | `2b5c2bf` plus the anchor-only source patch; no diagnostic probes. |

Final source is based on `2b5c2bf`. The installed application was not overwritten
by this task. Candidates and the final release were launched from this worktree.
No remote service was changed, and no conversation prompt was submitted.

## Evidence and cause

The matched baseline sample has 18,081 main-thread observations; 1,654 include
`NSHostingView.layout`, 481 include the row's `GeometryProxy.size` observation,
and 116 include `ConversationDocumentView.refreshVisibleRows`. These are nested
inclusive counts, not independent percentages or frame times. Most observations
are waiting; they do not establish a continuously blocked main thread.

Temporary numeric-only probes in the real application confirmed:

- Unmeasured rows reserve 160 pt. Actual short rows in this conversation are
  often 28–32 pt, while long reply rows reached 1,617 and 1,646 pt.
- Initial cold row measurements reached 22–27 ms. This includes initial
  conversation display; it is not a per-scroll-frame latency measurement.
- During upward scrolling, new estimated rows enter above already displayed
  rows. The old anchor lookup picks the estimated row at the viewport origin.
  Shrinking that row moves the displayed rows below it without a compensating
  scroll. Baseline logs show multiple 160-to-28/32 pt changes at unchanged clip Y.
- With the fix, the same real conversation selects an intersecting mounted row
  as its anchor. One observed batch shrank by 392 pt and corrected clip Y from
  11,037 to 10,645, preserving the displayed anchor's relative screen position.

The retained change is limited to anchor selection and its two callers. It uses
the existing geometry lookup when no mounted row intersects the new viewport.
Height measurement, bounded host retention, disclosure invalidation and follow
mode remain under their existing ownership. All temporary probes were removed.

## Rejected experiments and limits

Keeping nearby rows attached did not demonstrate a benefit: the 160-input real
scroll path consumed about 5.37 versus 5.31 process CPU-seconds. It was reverted.
Skipping identical frame assignments was also removed because no benefit was
established. These runs do not constitute a controlled frame-rate comparison.

An Animation Hitches recording took unusually long to finalize. Its exported
hitches table was empty; this is not evidence of hitch-free rendering.
Main-thread samples and numeric geometry logs are the usable evidence.

Cold SwiftUI/TextKit layout remains a performance limitation. This patch does
not claim to eliminate continuous dropped frames or all possible scroll jumps.

## Validation

The diagnostic release connected to the real remote session, scrolled upward
through cold history, performed small-step up/down reversals, expanded and
collapsed an actual tool record, and returned to the latest reply. The final
release repeated real-session acceptance after removing the probes: six
upward half-page inputs moved the scrollbar monotonically from 0.9761 to
0.8381, four downward inputs moved it monotonically to 0.9453, another 160
quarter-page inputs completed, and Return to latest hid the history button.
Scrollbar monotonicity is a functional check, not a frame-rate measurement.

Build, `WorkbenchChecks`, `ConnectionChecks`, strict deep signature verification
and `git diff --check` passed and are recorded separately from those live interactions.
The checks' synthetic connection coverage does not replace real-session evidence.

Local evidence is in `.local/real-scroll/` (ignored by Git): runtime identities,
the matched main-thread sample, numeric before/after geometry logs, and check
outputs. Additional raw captures remain in `/tmp/perch-real-scroll-20260923/`.
Raw Instruments captures can include process environment metadata and are not
included in the repository.
