# Frame diagnostics: recording slow frames on a real Mac

Transcript scrolling still drops frames "sometimes" on real devices, while every
earlier round measured CPU step times on synthetic fixtures. The frame recorder
captures slow frames on the user's own Mac, together with the main-thread work
that overlapped each one, so the next fix can target data. It is part of the
opt-in performance diagnostics (#175) and costs nothing while they are off.

## Record and export

1. Settings → 诊断 (Diagnostics) → turn on 性能诊断 (Performance diagnostics).
2. Optional: click 注入一次 120ms 卡顿（校验） (Inject one 120 ms stall) to confirm
   the recorder works on this Mac (see [Calibration](#calibration)).
3. Reproduce the jank: scroll a real long conversation until it stutters. Keep
   Perch in front; recording pauses while another app is active.
4. 导出诊断报告… (Export diagnostics report…) saves `perch-diagnostics.json`.
5. Turn diagnostics off when done. Turning them off clears the recording.

## What runs

- **Frame source** (`Sources/AgentWorkbench/FrameHitchMonitor.swift`): a
  `CADisplayLink` from the key window's screen (`NSScreen.displayLink(target:selector:)`,
  macOS 14+) on the main run loop in `.common` modes, so it also fires during
  event tracking. It follows key-window and screen changes, and restarts after
  screen reconfiguration, display or system sleep and session switches; the
  pause before a restart is never counted. It runs only while diagnostics are
  on and Perch is the active app. A local `.scrollWheel` monitor (events pass
  through unchanged) marks a frame as scrolling when a scroll event arrived
  within 300 ms before the frame's window began, or while momentum continues.
- **Recorder** (`Sources/WorkbenchCore/FrameHitchRecorder.swift`, Foundation
  only): the frame rule, counters, histograms, worst hitches, the work journal
  and attribution.
- **Probes**: `PerfDiagnostics.begin()` / `end(stage, probe, detail:)`. `end`
  also appends main-thread intervals to a 1,024-entry ring journal. `detail`
  is an autoclosure, so a disabled probe builds no strings.

### The hitch rule

Each callback gives `timestamp` and `targetTimestamp`; the frame's interval is
their difference, so no refresh rate is assumed (60 Hz, 120 Hz ProMotion and
variable rates read the same way). A frame whose gap since the previous callback
exceeds 1.5 × its interval is a **hitch**, with `round(gap / interval) − 1`
missed frames. The first frame after starting, and after each restart, only sets
a baseline.

### Attribution

On a hitch, the journal is clipped to the window (previous frame, this frame].
Each interval gets its **self time**: nested probes are subtracted (probes on one
thread nest; a later interval with the same bounds encloses an earlier one). Per
stage, self time and inclusive time are summed. Stage shares plus
`unattributed_ms` add up to the gap. `unattributed_ms` is time no probe covered:
AppKit/SwiftUI layout outside the probes, text drawing, Core Animation commits,
or other main-thread work.

## Calibration

注入一次 120ms 卡顿（校验） blocks the main thread for 120 ms inside a
`calibration_stall` probe. The exported report should then contain a hitch with
`gap_ms` of at least 120, whose first work entry is `calibration_stall` with
`ms` near 120 and `details: ["120ms"]`. If it doesn't appear, the recorder isn't
seeing this Mac's frames, and a scroll recording from it proves nothing.

## Report

Top level: `version`, `bundle_version` (CFBundleVersion, the commit count),
`source_revision` (PerchSourceRevision), `macos`, `generated`, `counters`,
`stages` (per-stage count, total and average ms; unchanged from #175) and `frames`:

| Key | Meaning |
| --- | --- |
| `recording_ms` | From recording start (turning diagnostics on, or the first event after a launch with them on) to the latest frame or interval |
| `display_interval_ms` | `last`, `min`, `max` frame interval seen |
| `counters` | `observed` frames with a measured gap, `scrolling`, `hitches`, `scrolling_hitches`, `missed_frames`, `scrolling_missed_frames` |
| `gap_histogram.by_interval` | Gaps in multiples of each frame's interval: ≤1.5, 1.5–3, 3–6, 6–12, >12 |
| `gap_histogram.by_ms` | Gaps in ms: ≤17, 17–34, 34–50, 50–100, 100–250, 250–500, 500–1000, >1000 |
| `worst_hitches` | The 60 largest gaps, largest first |
| `blame` | Per stage over every hitch, not only the retained 60: self `ms`, `inclusive_ms`, `hitches` it overlapped |
| `unattributed_ms` | Summed over every hitch |
| `journal` | `capacity`, `recorded`, `retained`, `dropped` intervals |

Histogram buckets hold `lower < gap ≤ upper`; the open last bucket has no `upper`.

Each worst hitch has `start_ms` (window start, relative to recording start),
`gap_ms`, `interval_ms`, `missed_frames`, `scrolling`, `phase`, `work` (the 8
largest stages by self time: `stage`, `ms`, `inclusive_ms`, `count`, and up to 3
distinct `details` from its longest intervals), `attributed_ms`,
`other_stages_ms` (stages beyond the 8), `unattributed_ms` and
`journal_truncated` (the ring had already overwritten intervals that may
overlap the window).

`phase` comes from the last scroll event: `began`, `changed`, `ended`,
`cancelled`, `may_begin`, `stationary` (trackpad gesture phases), `momentum`, or
`wheel` (a mouse wheel without phases).

### Stages

| Stage | Site | Detail |
| --- | --- | --- |
| `transcript_refresh` | `ConversationDocumentView.refreshVisibleRows`, passes that change the mounted range | `source`, `rows`, `entered`, `exited`, `created` |
| `row_setup` | `ConversationEntryController.setRoot` | `renderer` (`native_user`, `native_assistant`, `hosted` + `presentation`); hosted rows add `reason=selection` or the reply's top-level `blocks` kinds |
| `row_measure` | `ConversationEntryController.measure`, size-cache miss | `renderer` |
| `hosted_row_create` | `NSHostingController` creation in `setRoot` (`step=controller`) and its view in `loadView` (`step=view`) | `presentation` |
| `height_publish` | `ConversationDocumentView.publishHeight`, deferred publication | `rows`, `delta` (points) |
| `anchor_restore` | `ConversationDocumentView.restoreReadingPosition`, when it scrolls | `rows` |
| `snapshot_projection` | `ConversationTranscript.body`: presentation-model update and row list | `messages`, `rows` |
| `snapshot_apply` | `ConversationDocumentView.configure`: row reconciliation and refresh | `rows`, `reconciled`, `restructured` |
| `activity_derive` | `KimiWorkspaceView` / `NativeAgentView` body: the activity bar's `ConversationActivity` | `messages` |
| `session_select` | `WorkbenchModel.select`, including the connection's synchronous selection | `kind` |
| `catalog_refresh` | `WorkbenchModel.catalogChanged`: sidebar catalog rebuild and its follow-ups | `sessions` |
| `math_typeset` | `ReplyMathImage.entry`, cache miss | `mode`, `bytes` of TeX |
| `attributed_text` | `ReplyTextAttributes.paragraphs`, cache miss | `paragraphs` |
| `text_measure` | `ReplyTextView.measure`, cache miss | `length`, `wrapped` |
| `mermaid_disk_load` | `MermaidRenderer.loadDisk` (synchronous read and decode) | `bytes` |
| `mermaid_encode` | PNG encoding after a diagram snapshot | `pixels`, `bytes` |
| `calibration_stall` | Settings calibration | `120ms` |

`mermaid_render` stays in `stages` but not in the journal: it spans the web
view's awaits, so it is not contiguous main-thread work and would be blamed for
other work's frames. Its main-thread steps are journaled as the two
`mermaid_*` stages above. Connection and conversation state types are also
compiled into `ConnectionChecks`, which depends only on WorkbenchCore, so they
have no probes. Their snapshots are measured where the view layer applies them
(`snapshot_projection`, `snapshot_apply`, `activity_derive`), and selection where
the workbench calls them (`session_select`).

## Limits

- Main-thread hitches only. A late callback means the main thread could not
  have committed a new frame for that refresh. Work in the window server, Core
  Animation's render server or the GPU is not seen, and neither is a frame
  dropped there while the main thread was idle.
- Only frames while Perch is active are recorded, on the key window's screen.
- The journal holds the last 1,024 main-thread intervals. A very long stall full
  of probes can exceed it; such hitches say `journal_truncated: true` and
  undercount attributed work.
- Probes cover the sites above. Large `unattributed_ms` points to unprobed
  layout, drawing or commits; use Instruments (Points of Interest signposts,
  plus the `hitch` events this recorder emits) to look further.
- While recording, the display link runs at the screen's maximum refresh rate,
  which may keep a ProMotion display at that rate.

## Privacy

The report contains no message text. Details carry kinds and counts only:
renderer, block kinds, row and paragraph counts, byte lengths, pixel sizes. It
also carries the app version, source revision and macOS version. Nothing leaves
the Mac unless the user shares the exported file.

## Cost when off

No display link and no scroll monitor run, and the monitor observes only the
Settings toggle; its activation, key-window, screen and sleep observers exist
only while recording. Each probe is one lock-guarded Bool read, `end` returns on
the zero probe, and no detail string is built.

## Checks

- `WorkbenchChecks` → `checkFrameHitchRecorder` (Linux and macOS): steady frames,
  a long gap with overlapping work, nested and partial intervals, scroll flag,
  histograms, the worst-60 cap, ring overwrite, chain breaks, report encoding.
- `scripts/check-host-lifecycle.py`, phase `frame-hitch`: the production monitor
  with diagnostics off and on, the real display link and the calibration stall.
  It asserts a hitch of at least 100 ms attributed to `calibration_stall`. Below
  50 Hz the floor is 120 ms less one frame interval, because the late frame's
  vsync can precede the end of the stall. When the runner has no screen, or the
  display link delivers no frames within 1 s, it prints a `SKIP:` line instead
  of failing.
