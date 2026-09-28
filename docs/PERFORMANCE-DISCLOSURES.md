# Tool and thought disclosure latency

## Acceptance status: unresolved flicker

The user still reports conversation-region flicker and vertical jumps after
trying `2e52b71` through remote control. We do not yet know whether this is a
remaining rendering defect, remote-display behavior, or a combination. Geometry
and latency checks below do not prove that the visible problem is resolved.
Keep this change in draft pending a direct local-Mac trial of opening/closing
Bash and thought disclosures in the affected real conversation.

Large tool results and historical thoughts previously created one unbounded
`SelectableReplyText` on every expansion. TextKit measured the full text before
the main loop could continue. A separate SwiftUI transition also ran alongside
the native row-height animation.

The disclosure now starts with a 4,000-character preview. Short content remains
complete. “显示完整内容” reveals the original text and “复制完整内容” copies the
original source. Closing the disclosure discards that expanded preview state.
The explicitly requested live-thought popover still shows full text. Both the SwiftUI content transition and the native row-height animation are
disabled. Content, row frames and neighboring positions update together, with
the reading anchor retained. Unchanged expansion assignments are ignored.

## Local native measurement (2026-09-28)

The same fixture and compiler were used before/after the change, based on
`66ef654`. Each payload has 2,400 mixed Chinese/English lines, with three
expand/collapse cycles per type. No other build ran during these two recordings.

| Maximum main-loop observation gap per expansion | Before (median of 3) | After (median of 3) |
| --- | ---: | ---: |
| Bash output | 1,152 ms | 28 ms |
| Historical thoughts | 1,451 ms | 34 ms |

The observed expansion gaps ranged from 634–1,456 ms before and 27–35 ms after.
These are application-side intervals including an 8 ms sampling wait and native
layout/display submission, **not** GPU frame presentation or real-session
latency. The improvement includes the deliberate change from full text to a
bounded initial preview; explicitly revealing the full text still incurs full
layout cost. These first-fix measurements still included a 200 ms native
height animation; the follow-up below removes it.

The fixture checks expanded and collapsed row heights. Native UI inspection
also verified the full thought's final line (`Line 2399`), the full-copy control,
returning to preview, and rapid toggles restoring the following reply.
WorkbenchChecks, the release app build, and native scroll-following checks were
run separately. No remote Agent, user conversation, or installed app was changed.

Local raw reports are retained under `.local/disclosure-long-baseline/result.json`
and `.local/disclosure-long-current/result.json`. Reproduce from a built checkout:

```sh
scripts/build-navigation-preview.sh
NAVIGATION_AUTORUN=disclosure NAVIGATION_AUTOQUIT=1 \
  NAVIGATION_RESULTS="$PWD/.local/disclosure-results" \
  "build/Navigation Preview.app/Contents/MacOS/NavigationPreview"
```

Compare equal fixture hashes and window geometry; run without a concurrent build.
The test-only binding registry is enabled only for this scenario and cleared on exit.

## Follow-up: flicker and position jumps

The first fix (`a4bb195`) improved latency, but the user still observed the
conversation region flashing and moving during clicks. Final-height checks had
missed the intermediate layout. With the original 200 ms native animation,
19–22 sampled display submissions per toggle had different heights for the
hosting content and its clipping row, with up to 2,057 points of mismatch.

The follow-up removes that timer, updates neighboring native frames before
publishing the document height, and captures a reading anchor before changing a
disclosure. Anchor restoration waits for the document's final height on both
expansion and collapse. No clipping-height tween is retained.

On the local fixture, all 12 open/close operations had **zero** mismatched
samples after the change. A second scenario places the clicked row between long
messages: all 12 operations also kept its on-screen title at exactly the same
position. These are native geometry/display-submission checks, not a claim about
WindowServer presentation or the user's remote session. Raw reports remain in
`.local/disclosure-flash-before`, `.local/disclosure-flash-after`, and
`.local/disclosure-flash-anchor`.

```sh
NAVIGATION_AUTORUN=disclosure NAVIGATION_ASSERT_ATOMIC_DISCLOSURE=1 \
  NAVIGATION_DISCLOSURE_CONTEXT=1 NAVIGATION_AUTOQUIT=1 \
  NAVIGATION_RESULTS="$PWD/.local/disclosure-flash-anchor" \
  "build/Navigation Preview.app/Contents/MacOS/NavigationPreview"

# Package separately while the previous Perch bundle is still running.
WORKBENCH_APP_DIR="$PWD/build/Perch-Disclosure-Fix.app" scripts/build.sh
```
