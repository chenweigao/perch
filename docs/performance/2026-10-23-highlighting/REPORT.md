# File switching and background colors

Baseline: `a089282afbe7f2f540b05c8ed651fac31da76586`. Candidate source digest and toolchain are in [metadata.json](metadata.json).

## Change and bounds

Keep highlight.js and native TextKit drawing. Sources above 256 KiB use a separate actor and JavaScriptCore VM, so a synchronous large parse does not occupy the small-file/code-card actor. Cache immutable tokens using LRU order: at most 24 entries / 8 MiB for small source and 2 entries / 32 MiB for large source. Budgets count UTF-16 source and token storage, not total process or JavaScript heap memory. The 4 MiB input retained 18,671,352 estimated cache bytes.

Cancellation is checked before queued work, after JavaScript and during XML decoding. A JavaScript parse already executing cannot be interrupted by Swift task cancellation; its result is discarded. Switching to small source proceeds independently. Two large uncached requests still serialize on the large-file actor. No views or attributed text are cached.

## Matched measurement

Three fresh processes per arm, alternating baseline/candidate order, on the same arm64 Mac running macOS 27.0.1, Swift 6.4, Swift 5 mode, macOS 26 target, `-O -whole-module-optimization`. No concurrent build or profiling job during measurement; unrelated system load was not measured. Input is the same 4 MiB repeated/truncated `remote/native-agent-service.py` in each run. Start its background parse, wait 60 ms, request a small Swift source, then reopen the same large source. Both arms return 432,752 tokens covering the exact original UTF-16 extent.

| Operation | Baseline median (range), ms | Candidate median (range), ms |
| --- | ---: | ---: |
| Small-file colors requested during large parse | 4,006.33 (3,986.70–4,028.92) | 10.15 (10.13–10.16) |
| Repeated large-file colors | 4,094.14 (4,065.24–4,241.41) | 11.99 (11.86–12.04) |
| Cold large-file completion | 4,075.52 (4,054.36–4,095.31) | 4,064.10 (4,056.82–4,174.84) |

The cold parse is effectively unchanged. Repeated requests parsed again in every baseline run and hit the cache in every candidate run. Peak process RSS was 341.7–343.2 MiB baseline and 324.5–325.2 MiB candidate; this includes temporary parsing allocations and is not the retained-cache size or a full-app memory measurement.

These are background token scheduling/cache measurements. They exclude file/SSH reading, window layout, displayed frames, physical input and scrolling. They do not establish FPS or real remote-session performance.

Reproduce after stopping other build/profiling jobs:

```sh
python3 scripts/benchmark-code-highlighting.py --baseline a089282 --runs 3 --output .local/highlight-comparison
```

Raw observations: [matched.jsonl](matched.jsonl). Production component regressions are in `Tests/HostLifecycleChecks/CodeReaderChecks.swift` and `WorkflowPolishChecks.swift`.
