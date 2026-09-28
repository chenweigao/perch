# Tool and thought disclosure latency

Large tool results and historical thoughts previously created one unbounded
`SelectableReplyText` on every expansion. TextKit measured the full text before
the main loop could continue. A separate SwiftUI transition also ran alongside
the native row-height animation.

The disclosure now starts with a 4,000-character preview. Short content remains
complete. “显示完整内容” reveals the original text and “复制完整内容” copies the
original source. Closing the disclosure discards that expanded preview state.
The explicitly requested live-thought popover still shows full text. The native
row retains its 0.2-second height animation; SwiftUI no longer runs a competing
content transition, and unchanged expansion assignments are ignored.

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
layout cost. The animation itself intentionally takes about 200 ms.

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
