# Session directory and workbench home — 2026-10-29

The All Sessions directory now uses reusable native AppKit cells. The workbench
opens on current work, with Projects and Task Groups as separate tabs and one
sidebar Workbench destination. See [design](../../design/workbench-home.md).

## Measured directory cost

Matched Release fixtures on the same Apple M4 Mac mini, macOS 27.0.1 (26A434),
Swift 6.4, 1920×1080 display at 60 Hz. Window 1280×820 points; 500 catalog sessions,
474 unarchived rows, 200 history turns, eight resident snapshots. The production
project sidebar is enabled. Each fresh process traverses the entire directory
down and up in 80 steps and applies six search queries, including Chinese,
English, directory, exact ID, no results and clearing the query.

| Local layout boundary | Baseline, 3 runs | Native cells, 3 runs |
| --- | --- | --- |
| Open to laid-out directory | 98.3–104.4 ms | 89.3–94.1 ms |
| Scroll step median | 28.5–29.6 ms | 7.1–7.4 ms |
| Scroll step p95 | 33.8–36.5 ms | 8.2–8.4 ms |
| Worst scroll step | 38.5 ms | 11.4 ms |
| Query update median | 62.6–66.9 ms | 34.3–35.8 ms |
| Query update p95 | 68.7–75.4 ms | 38.1–40.1 ms |
| Settled process RSS | 299–304 MiB | 205–207 MiB |

Median-of-run-medians: scroll 28.72 → 7.30 ms (74.6% less), search
64.66 → 35.65 ms (44.9% less). At most 12 directory cells were mounted.
Actual native row count, titles and online availability were checked after
scrolling and query changes; all three runs passed. Timings end at local
layout/display/CA flush and exclude keyboard/IME delivery and compositor
presentation. These are not FPS or physical trackpad latency measurements.

Baseline is origin/main e27fa3e plus the measurement harness. The measured
candidate includes the native-cell implementation and workbench redesign.
[measurements.json](measurements.json) records exact source and binary hashes;
the full local manifests and logs are under .local/home-evidence. The installed
0.2.1 build 748 was separately inspected and sampled; it is older than this
baseline and must not be treated as the same binary.

## Functional and real-window evidence

- Release build via scripts/build.sh; 76 WorkbenchChecks passed. The optional
  live SSH check was skipped.
- Localization coverage and all four localization tests passed.
- Existing native dashboard scenario passed with 60 catalog updates.
- Isolated native window: search, empty results, keyboard Down/Return opening the
  correct session, ellipsis and right-click menus, group detail, and overview.
- Production application launched from this task's build/Perch.app; the process
  path was verified. Its real 151-session catalog loaded, scrolled and searched
  (13 results for perch). Projects and Task Groups tabs were exercised in dark
  appearance. No task prompt or destructive menu action was sent.

The final visual polish puts titles above metadata and hides the redundant
picker label. Performance distributions above precede that visual-only polish.
The [follow-up validation](final-validation.json) also passed: 7.44 ms scroll
median, 8.49 ms p95, 36.55 ms search median, and 12 mounted cells. The workbench
New Session action then switched to the system bordered style for dark-mode
contrast; it does not affect the directory. The final production window was
reopened to verify its readable label. [delivery-build.json](delivery-build.json)
records the delivered source and executable hashes and its 76 passing core checks.
No installed bundle was overwritten. No hosted CI, merge, deployment or new
remote-provider compatibility claim is made.
