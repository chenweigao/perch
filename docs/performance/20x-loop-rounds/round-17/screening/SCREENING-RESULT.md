# Round-17 screening (Mac mini + Linux, 2026-11-15) — normalizeDelimiters byte guard PASSED in-context screening on BOTH platforms

Candidate: replace `ReplyMath.normalizeDelimiters`'s entry guard (two
grapheme-aware `contains("\(")` / `contains("\[")` substring searches, plus
the byte-level `contains(92)`) with a single UTF-8 byte scan; the original
searches remain as the fallback for delimiter-byte pairs followed by a
non-ASCII byte (grapheme-extension inconclusive at byte level). Equivalence
argument and the guard/scan asymmetry corner are pinned by
`checkNormalizeDelimitersByteGuard` (structural cases + 3,000-text fuzz
digest).

Per the round-15 lesson (isolated microbenchmarks do not extrapolate in
either direction), screening ran IN CONTEXT — the bench modes themselves —
on both platforms, before opening the formal six-pair measurement.

## Golden capture (equivalence, both platforms, base == candidate)

| platform | base (76940c0 + pin) | candidate (+ guard change) | checks |
| --- | --- | --- | --- |
| macOS 27.0.1 arm64 | `d90ac2cad4b58020` | `d90ac2cad4b58020` | 99 PASS both sides, exit 0 |
| Alibaba Cloud Linux 3 x86-64 | `d90ac2cad4b58020` | `d90ac2cad4b58020` | 98 PASS + 1 SKIP both sides, exit 0 |

The corpus deliberately avoids URL shapes, so neither link backend feeds the
digest and ONE golden holds on every platform including CI (round-16
lesson applied by construction). 412/3000 fuzz texts exercise the converting
path (density guard >100).

## In-context timing (3 alternating iterations per platform; medians of the
## bench's own output; screening-grade, not the adoption measurement)

Mac mini (driver log `screen-mac-driver.log`, job `screen-mac-job.sh`):

| metric | base | candidate | note |
| --- | --- | --- | --- |
| find_bar_cold_query | 1295.58 / 1299.24 / 1304.71 | 1177.08 / 1190.21 / 1216.56 | **-8.4% median, 3/3 separated** (cand max 1216.6 < base min 1295.6) |
| find_bar_query_update (warm) | 0.27 / 0.27 / 0.29 | 0.28 / 0.28 / 0.28 | print-grid, no signal |
| chain_total | 0.58 / 0.59 / 0.61 | 0.57 / 0.59 / 0.58 | noise |
| cold@2000 (mode 1) | 6.87 / 6.88 / 6.71 | 6.92 / 6.76 / 6.86 | unchanged — the cold-projection path's parsing share is small; gain is concentrated in the find-bar full-window search |

Linux (streaming mode; screen logs under `.local/round17/linux-screen/`):

| metric | base | candidate | note |
| --- | --- | --- | --- |
| find_bar_cold_query | 700.38 / 701.35 / 697.69 | 612.22 / 610.26 / 611.17 | **-12.7% median, 3/3 separated** — the change is platform-neutral byte scanning; corelibs' grapheme-aware contains pays the same toll |
| find_bar_query_update (warm) | 0.53 / 0.54 / 0.53 | 0.55 / 0.54 / 0.55 | +1 print step on 2 of 3 iterations — watch item for the formal run |
| chain_total | 1.35 / 1.37 / 1.35 | 1.38 / 1.36 / 1.38 | +~1% — watch item for the formal run |

## Decision

PASSED on both platforms — opened the formal round (six-pair A/B at the
golden-embedded head 815aa65). Watch items carried into the formal run: the
Linux warm-path/chain_total +1-grid/+1% screening signals (expected print-grid
noise; the warm path re-renders only the latest turn per delta, where the
guard now also runs. No construction argument is offered — measurement
decides: the formal v3 run measured warm at 0.00% median on Mac (worst
+3.70% within 7.41% spread) and +1.87% on Linux (worst 5.77% within 7.69%
spread), both in band; per-pair samples are in the JSONs.
