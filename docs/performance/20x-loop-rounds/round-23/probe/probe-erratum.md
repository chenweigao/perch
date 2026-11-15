# Round-23 probe erratum (review F7)

## Corrections to the v1 probe record

The v1 probe (`substr-eq-probe.swift`, kept unmodified as historical
evidence; output `substr-eq-probe-linux.txt`) had two defects:

1. **"different lines" row invalid (short-circuit).** The timing loop
   accumulated with `acc = acc && body()`. For the always-false
   different-lines case, `body()` stopped being called after the first
   false — 7 total invocations across 7 rounds, not 1.4M. The v1 figure
   0.071ms/200k and its derived "~0.4ns fast false" conclusion are
   **retracted**.
2. **Raw byte-loop cost was never measured.** The report's "~1-2ns bare
   memory comparison" claim for the candidate's fast path was an
   untested estimate and is **deleted**.

The always-true v1 rows were not short-circuited (every call evaluated)
and are confirmed by v2 within run-to-run variation.

## Corrected probe v2 (authoritative)

`substr-eq-probe-v2.swift`, output `substr-eq-probe-v2-linux.txt`
(Linux, Swift 6.3.3, `swiftc -O`, 200k comparisons x 7 rounds best-of).
v2 defeats BOTH pitfalls: XOR accumulation calls every comparison (no
short-circuit) and indexes a pre-built 64-pair array by the iteration
counter (defeats loop-invariant hoisting — a first v2 draft with constant
inputs measured 0.000ms, i.e. the optimizer lifted the comparisons; that
draft is not recorded as evidence).

| comparison shape | v1 | v2 (authoritative) |
| --- | --- | --- |
| ascii same-base identical | ~0.3ns | ~0.2ns |
| cjk same-base identical | ~0.3ns | ~0.2ns |
| **cjk cross-base byte-identical** | ~15ns | **~16ns** |
| **cjk canonical-equal, byte-differing** | ~309ns | **~309ns** |
| cjk different lines | ~~0.4ns (invalid)~~ | **~13.5ns** |
| raw byte loop, cross-base identical, per-call `withUTF8` | not measured | **~27ns (probe shape)** |

Notes on the raw-loop row: the probe pays two `withUTF8` acquisitions per
timed call; the product's `lineRangesEqual` runs inside one outer
`withContiguousStorageIfAvailable` per `fullLineDiff` call, so its
per-line cost is the indexed byte loop alone — **not separately measured**.
No per-line nanosecond figure is claimed for the product fast path.

The load-bearing mechanism facts survive correction: cross-base
byte-identical `Substring ==` costs ~16ns vs ~309ns for the
canonical-equal byte-differing comparison (~20x), so (a) canonical
fallback is the expensive branch the design reserves for byte-differing
pairs, and (b) byte-identical pairs already have a stdlib byte fast path
whose ~16ns dispatch the candidate's in-loop byte comparison avoids or
matches — the adopted magnitude comes only from the in-context A/B, which
also carries the elimination of the two `[Substring]` array
materializations (index arithmetic + ARC + array growth per line).
Adoption is decided solely by in-context six-pair A/B; the probe informs
mechanism only (round-15 isolated-microbench discipline).
