# Round-19 screening (Mac mini + Linux, 2026-11-15) — splitInline byte-level dollar guard PASSED on both platforms

Candidate: `ReplyMath.splitInline`'s per-run guard `run.text.contains("$")`
(a Character-by-Character walk over every paragraph run) →
`run.text.utf8.contains(36)` (byte-level; 0x24 is self-synchronizing in
UTF-8). Equivalence: byte presence is necessary for a "$" Character; the
extra admitted runs (every "$" fused into a larger Character, e.g. GB9b
after a Prepend scalar) make `split()` return one value-equal run — parse
output identical for all inputs.

Motivation: round-17's pure cold find-bar attribution (21,222 samples) put
the splitInline closure at 795 samples (~3.7% of all) although the bench
corpus contains NO literal math — the cost is the guard walking every run
of every entry to find nothing.

Per the round-15 lesson, screening ran IN CONTEXT (bench modes) on both
platforms BEFORE the formal round, and the equivalence pin was captured on
the unmodified product first.

## Golden capture (equivalence, four-way identical)

| platform | base (89e5976 + pin) | candidate (+ guard) | checks |
| --- | --- | --- | --- |
| macOS 27.0.1 arm64 (Swift 6.4) | `5d1506ed4a822a53` | `5d1506ed4a822a53` | 100 PASS both sides, exit 0 |
| Alibaba Cloud Linux 3 x86-64 (Swift 6.3.3) | `5d1506ed4a822a53` | `5d1506ed4a822a53` | 99 PASS + 1 SKIP both sides, exit 0 |

ONE golden across platforms (999/3000 fuzz texts extract math): splitInline
is pure stdlib Character logic — unlike the link backends (round 16/17), no
Foundation divergence exists here, so the single digest is CI-enforceable.

## In-context timing (3 alternating iterations per platform; medians; screening-grade)

Mac mini (driver log `screen-mac-driver.log`, binaries run in place):

| metric | base | candidate | note |
| --- | --- | --- | --- |
| find_bar_cold_query | 1178.14 / 1192.20 / 1183.54 | 1114.28 / 1115.44 / 1116.10 | **-5.75% median, 3/3 separated** (cand max 1116.1 < base min 1178.1; gap ~62ms ≈ 10x the iteration band) |
| cold@2000 (mode 1) | 6.67 / 6.67 / 6.63 | 6.69 / 6.67 / 6.81 | unchanged — the cold-projection path is not splitInline-dominated |

Linux (`screen-linux-cold.log`):

| metric | base | candidate | note |
| --- | --- | --- | --- |
| find_bar_cold_query | 615.25 / 611.98 / 616.08 | 554.00 / 554.63 / 552.58 | **-10% median, 3/3 separated** |
| cold@2000 (mode 1) | 48.26 / 48.54 / 48.37 | 48.67 / 48.39 / 48.03 | unchanged |

## Decision

PASSED on both platforms — opened the formal round (six-pair A/B at the
golden-embedded head fe17ef1; primary metric find_bar_cold_query on Mac).
The Mac gain (-5.75%) EXCEEDS the attribution-based estimate (~3.7%):
Character-level `contains` costs more per byte than the sample attribution
suggested (its work lands partly in stdlib frames shared with other call
sites). No harness artifacts this round: binaries ran in place (round-18
lesson), all equivalence outputs non-empty.
