# Bound old transcript teardown work between switches

**Final decision:** retain the 2 ms/four-graph budget with 1 ms rescheduling. Reject the intermediate 10 ms-rescheduling variant. Keep the original decoding/search/selection improvements. This is an incremental improvement, not completion of all long-history latency goals.

2026-09-21. Follow-up to [the performance-paths review](PERFORMANCE-PATHS-REVIEW.md). Keep the verified decoding/search/idle-polling improvements, integrate main `0725eed`, and address a separate UI hotspot with one small change.

## Evidence and change

A three-second main-thread sample during 80 synthetic cache-hit switches traversed both hosting-controller measurement and retired-controller destruction. The retired-controller drain appeared in 351 samples, and `ConversationEntryController.measure` in 296. These are stack observations, not additive percentages or an end-to-end causal attribution. The sampled run is excluded from timing comparisons; raw system stacks remain local.

The previous drain released four old SwiftUI hosting graphs per batch regardless of their cost. It now checks elapsed time after each graph's autorelease pool drains, yielding once roughly 2 ms has been consumed. It retains the original maximum of four graphs and main-thread-only destruction. A single graph cannot be interrupted, so 2 ms is a scheduling budget, not a hard latency bound. Rendering, row identity, history coverage, layout estimates and disclosure behavior are unchanged.

## Same-source A/B short checks

Both apps use the same integrated Core, dependencies and fixture. Only the teardown loop differs. Build both before measuring, then run A-B-B-A serially without sampling or concurrent compilation. Each run fully reads the same 200 mixed-content turns, checks the last mounted row, performs 240 warm scroll steps and 40 distinct cache-hit switches across the production-sized eight-conversation cache.

| Metric | before 1 | after 1 | after 2 | before 2 |
| --- | ---: | ---: | ---: | ---: |
| Switch median | 55.43 ms | 49.31 ms | 45.99 ms | 60.28 ms |
| Switch p95 | 68.88 ms | 58.17 ms | 52.17 ms | 70.66 ms |
| Switch maximum | 78.87 ms | 60.38 ms | 57.08 ms | 79.00 ms |
| Warm scroll p95 | 9.33 ms | 8.68 ms | 7.42 ms | 9.58 ms |
| Observed turns / last row | 200 / yes | 200 / yes | 200 / yes | 200 / yes |

Averaging the two run medians, switching took about 18% less time; averaging their p95s, the tail took about 21% less time. No switch exceeded 100 ms in these four runs. This shows a repeatable local improvement; it does not prove that all sources of the earlier 133–212 ms outliers are eliminated. Programmatic measurements exclude mouse delivery, network latency and GPU presentation. The first-read/whole-app performance goals remain separate.

Build metadata, binary hashes, all timing results and exit reports are in [the evidence directory](performance/2026-09-21-release-budget/). The fixture supervisor now accepts `--app` so independently built A/B apps retain their binary identity; it still requires an explicit final report and successful exit. Short-soak progress is recorded every ten seconds rather than once a minute.

## Bounded stress result and remaining limitation

The candidate completed 124.7 seconds of continuous switching, large scroll jumps and search toggles: 69 switches, 828 scroll steps, nine search changes, successful exit and a final report. RSS rose from about 124 MB idle during initial allocation, then fluctuated around 199–249 MB in the later samples, ending near 230 MB. No monotonically growing retained-view footprint was observed in this short window; this is not a long-term leak guarantee.

This workload remains janky: switch p95 was 457 ms and scroll p95 533 ms, with a 2.18-second maximum scroll step. It is deliberately different from warm continuous reading. The process/content checks passed, **the stress workload's latency did not**. A matching before-change stress run is recorded separately to check whether the small teardown budget introduced this behavior.

The matching before-change stress run completed 112 switches / 1,344 scroll steps in 120 seconds; switch p95 164 ms, scroll p95 286 ms. The 2 ms budget combined with the old 10 ms sleep regressed sustained throughput (69 vs 112 switches), despite improving warm-switch latency. That intermediate variant is rejected. A follow-up retains the 2 ms/four-graph budget but reschedules after 1 ms to avoid starving teardown under sustained switching. Its results must be evaluated separately; the warm results above do not certify it.

## Final retained variant: 2 ms budget, 1 ms rescheduling

The final ordinary-reading checks had switch medians 60.36/55.60 ms, p95 69.52/64.12 ms and maxima 70.55/67.85 ms (40 switches each); no switch exceeded 100 ms. All 200 turns and the final row were present. Warm-scroll p95 was 13.20/9.98 ms. These are broadly comparable to the original ordinary-reading results; **the rejected variant's roughly 18% warm-switch improvement is not claimed for the shipped code.**

The retained variant's two-minute stress run completed 141 switches and 1,692 scroll steps in 122.0 seconds, versus 112/1,344 in 121.0 seconds before the change. Switch p95 improved from 164.46 to 83.80 ms, and scroll p95 from 285.97 to 87.69 ms. Switch maximum improved from 860 to 450 ms; worst scroll steps remained about 2.2 seconds in both variants. Late RSS fluctuated around 185–228 MB and ended at 196 MB. This supports the short-window throughput/latency improvement without a continuously rising memory trend, but does not establish a general leak or long-soak guarantee. There is one full stress run per variant; retain that sampling limit.

The remaining rapid cross-page stalls are an existing limitation and are not marked resolved. No 20-minute soak was attempted. All runs exited normally with final reports; passing execution/content assertions is separate from passing latency targets.

Validation: Release app/signature, WorkbenchChecks, ConnectionChecks, localization coverage and all 38 isolated remote Python tests passed for the integrated changes. Remote providers and formal sessions were not exercised or modified. Updated main's subsequent model-picker and link changes are incorporated before PR submission; the controlled timing comparison above was built with main `0725eed` plus the original performance changes, using matching dependencies and Core on both sides.
