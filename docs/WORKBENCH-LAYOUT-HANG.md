# Workbench layout hang (2026-09-23)

The installed Mac app stopped responding on the workbench at about 99% CPU.
A five-second sample kept the main thread in SwiftUI transactions and lazy
placement (`GraphHost.flushTransactions`, `LazySubviewPlacements`,
`LazyStack.place`, and `LazyLayoutViewCache.updateItemPhases`). Its physical
footprint was about 310 MB.

## Reproduction and fix

The offline production-workbench acceptance fixture reproduces the hang on
`5b3b910` with the regression probe added and the original `LazyVStack` intact.
After 33 completed dashboard updates, the next update stopped progressing and
CPU stayed near 99%. A three-second sample showed the same lazy-placement call
path as the live app. The external supervisor terminated the stalled fixture
after 84 seconds; no passing result was produced.

Use `VStack` for the dashboard's outer section container. These are a small
number of variable-height groups, each of which already lays out its rows
eagerly. Lazily estimating their heights while status updates add/remove and
reorder sections caused the reproduced placement loop. Home's row limits,
disclosures, row identities and inbox contents are unchanged. This does not
replace the lazy lists in the separate full session directory or search.

## Regression

```sh
./scripts/build-native-acceptance.sh
python3 scripts/run-native-acceptance.py --mode dashboard --output .local/dashboard-check
```

The fixture uses 500 catalog sessions. It changes status, row height, ordering
and online state across 60 updates while switching between home and inbox and
scrolling. A compile-time-only probe checks the rendered projection and inbox
mode. The test checks idle CPU, returns to the original transcript, then runs
the existing 120-step history-scroll and retained-view checks. The independent
process supervisor detects hangs even when the main actor cannot run a timeout.

The fixed run passed all 60 updates and the subsequent 120 scroll steps in
25.04 seconds. Settled CPU was 0.099 CPU-seconds over two seconds, and settled
resident memory was 183.9 MB. The A/B binaries differ only in the dashboard's
outer stack and its explanatory comment; both include the same acceptance
probe. See [comparison.json](performance/2026-09-23-workbench-hang/comparison.json)
for source/binary hashes, compiler and bounded-run results. These timings include
fixture-driven changes and local rendering, not hardware input latency.

The release build, `swift run --build-system native -c release WorkbenchChecks`,
`ConnectionChecks` and strict deep signature verification passed. The automated
SSH integration check was skipped because `WORKBENCH_LIVE_HOST` was unset.
After backing up the old app and workspace, the release was installed locally.
The real workbench loaded remote session rows, scrolled, expanded its pending
restoration group, switched to the inbox and returned home without hanging.
This live smoke check does not certify every restored remote environment.

This is a local deterministic reproduction. It does not reproduce the exact
remote event sequence or measure network latency, hardware input latency or
frame smoothness. Raw local samples and A/B artifacts remain under `.local/`.
