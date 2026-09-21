# Performance paths branch: isolated Mac comparison

2026-09-21. Tested `origin/fix/performance-paths` at `833b92c` on top of current main `5cd50ee`. The branch merged without source conflicts. **The decoding, repeated-search and idle-snapshot optimizations are effective; this is not acceptance of improved overall navigation or scrolling. Do not merge on an overall smoothness claim.**

One integration defect was fixed in this test branch: the new native snapshot test omitted main's required `completed` field, so WorkbenchChecks initially crashed with `DecodingError.keyNotFound`. The synthetic fixture now supplies `completed: 0`; the real bridge already supplies it. Production decoding was not weakened.

## Targeted measurements

Identical Release fixtures, 200 synthetic turns / 400 messages, about 392 KB of JSON, mixed Chinese/English, thinking and Markdown. Each Swift metric has seven samples; the two runs per variant use A-B-B-A order. The table averages the two run medians. Builds finished before measurement, with no concurrent benchmark. Checksums match.

| Path | main | candidate | Ratio |
| --- | ---: | ---: | ---: |
| Kimi history decode | 16.30 ms | 3.74 ms | 4.36× |
| Native snapshot decode | 23.29 ms | 3.63 ms | 6.41× |
| Kimi streaming event decode | 0.0173 ms | 0.0089 ms | 1.96× |
| Repeated searches | 31.53 ms | 3.87 ms | 8.15× |
| First search | 31.20 ms | 30.36 ms | 1.03× |

The baseline native benchmark reproduces the old request/JSONValue/re-encode/snapshot sequence; the candidate calls NativeAgentWire and NativeSnapshotResponse. Event timing includes decoding only, not SwiftUI publication/layout or token-to-display latency. Search results are consumed and validated, not optimized away.

The Python bridge fixture, running locally with temporary state and no agents, reduced an unchanged revision read from about **4.44 ms to 0.00043 ms** by avoiding history deepcopy. Changed snapshots were roughly unchanged (4.52 vs 4.21 ms). This benefit requires deploying the updated remote bridge; no deployment was performed. It is not a network or end-to-end latency measurement.

The connection tests verified immediate native selection reads, A→B→A stale-response rejection (including a cancellation-ignoring transport), and disconnect cancellation. This removes waiting for the next 400 ms polling cycle before a selection request starts; it does not guarantee a particular network response time.

## 200-turn UI short comparison

Production transcript components; 500 synthetic catalog entries, eight cached conversations with distinct message IDs. Each run fully traverses 200 mixed-content turns, verifies the final row, scrolls 240 steps through the now-read history, then switches 12 times. A-B-B-A order. All four runs observed every turn and the final row; document heights matched at 104,185 pt. Each exited normally and produced its final report.

| Metric | main 1 | candidate 1 | candidate 2 | main 2 |
| --- | ---: | ---: | ---: | ---: |
| Switch median | 51.01 ms | 60.16 ms | 55.81 ms | 54.24 ms |
| Switch p95 | 53.71 ms | 99.04 ms | 130.77 ms | 73.77 ms |
| Switch maximum | 54.42 ms | 132.70 ms | 155.88 ms | 211.78 ms |
| Switches >100 ms | 0/12 | 1/12 | 2/12 | 1/12 |
| Warm scroll p95 | 8.60 ms | 8.23 ms | 10.37 ms | 9.12 ms |
| First traversal p95 | 37.04 ms | 38.00 ms | 37.93 ms | 34.82 ms |

No clear scrolling improvement. Candidate switching medians and tails were worse in these small samples; main also had a 212 ms outlier. This establishes an unresolved regression signal, not its cause. Twelve switches per run do not give a reliable population p95. The changed decoding/search/polling paths are not exercised by cached UI switches, so the data cannot causally attribute these tails to them. The previous short-test switching/first-read goals are not consistently met. **No long soak was run.**

These are programmatic selection/scroll → layout/display/transaction measurements, not mouse-to-photon or display-link frame rates. The test uses synthetic scope data, not the full live WorkbenchModel. `status: passed` in navigation JSON means content/execution assertions completed, not that performance thresholds passed.

## Checks and reproduction

- Release app built and signed. WorkbenchChecks and ConnectionChecks passed after the fixture fix.
- All 22 remote Python tests passed, including approval expiry and unchanged-snapshot copy avoidance.
- No live SSH tests, provider calls, formal sessions, production app replacement, or remote bridge deployment.
- Local test branch only; main and the upstream performance branch were not modified.

After building matching Release cores at the baseline and candidate paths:

```sh
bash scripts/build-performance-paths.sh /path/to/baseline baseline
bash scripts/build-performance-paths.sh "$PWD" candidate
.local/performance-paths/baseline baseline
.local/performance-paths/candidate candidate
python3 scripts/benchmark-native-snapshot.py /path/to/baseline baseline
python3 scripts/benchmark-native-snapshot.py "$PWD" candidate
bash scripts/build-navigation-preview.sh
python3 scripts/run-navigation-check.py reading --switches 12 --output .local/navigation-new-run
```

Run A-B-B-A serially, never while compiling. Baseline was built from `15fe7ed`, whose tree matches main `5cd50ee`; candidate includes main plus `833b92c` and the test fixture correction. Source/binary fingerprints and all measurement JSON are in [the evidence directory](performance/2026-09-21-performance-paths/). Raw traversal traces remain local.
