# Sidebar renderer experiment

The experimental NSTableView container improves catalog-only work, but is not
adopted in production. The user's reported pain is long-conversation scrolling
and disclosure, which this experiment does not resolve. Production retains the
existing SwiftUI container and Liquid Glass surface.

One fixed Release diagnostic binary, three interleaved runs per renderer and
workload (42 timed runs), no concurrent profiling/builds. Entries, row content,
actions and session identity are shared. All timed runs passed their fixture
contracts. `results.json` retains build hashes, configuration and run summaries.
Numbers below are medians of the three per-run statistics, in milliseconds.

| Workload | SwiftUI median / p95 | Table median / p95 |
| --- | --- | --- |
| Pin membership, without row probes | 20.20 / 23.00 | 7.89 / 11.20 |
| Subtitle-height transitions | 22.73 / 25.78 | 13.55 / 15.93 |
| Catalog updates | 26.76 / 31.13 | 20.88 / 28.18 |
| Catalog plus conversation switching | 81.05 / 94.17 | 76.45 / 86.70 |
| Conversation switching | 64.09 / 71.00 | 60.35 / 65.51 |
| Paced joint input | 7.10 / 8.61 | 6.75 / 8.38 |
| Paced joint updates | 26.43 / 28.33 | 26.17 / 28.28 |

The large local container gain shrinks to about 5.7% in the mixed workload;
paced joint updates barely change. This does not meet the proposed 15% broader
adoption gate. These are mutation-to-layout/display measurements, not FPS.

The new cooperative main-actor sampler detected both injected 80ms controls
(79.97/80.13ms). In the paced 30-second joint runs, p99 lateness was roughly
9–12ms; occasional wake-ups exceeded 50ms in both renderers. Continuous stress
had larger delays. Scheduler lateness includes OS scheduling and does not prove
display smoothness, hardware input latency, or physical IME behavior.

Functional structure checks cover collapse, hidden updates, filtering, last-pin
removal and recycled visible-row identity. This is an acceptance-only prototype:
section/group heights assume the current font/layout. Keyboard navigation,
accessibility parity, all hover/menu behavior and real display frames remain
unverified. The prototype cannot be enabled by production configuration.

Final-source functional checks passed for both containers: full workbench,
detail lifecycle and Kimi input. Production build/signature, WorkbenchChecks,
ConnectionChecks, 22 performance-tool tests, localization and scroll-following
also passed. The read-only real SSH check was skipped. See `validation.json`;
these later functional runs are not mixed into the frozen timing matrix.

See `ACCEPTANCE.md` for proposed experience targets and evidence boundaries.
Raw runs and fixed app are local under `.local/sidebar-renderer/`.

```sh
python3 scripts/summarize-renderer-experiment.py .local/sidebar-renderer \
  --output docs/performance/2026-09-29-sidebar-renderer/results.json
```
