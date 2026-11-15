# Round-19 screening (Mac mini + Linux, 2026-11-15) — splitInline byte-level dollar guard PASSED on both platforms

Candidate: `ReplyMath.splitInline`'s per-run guard `run.text.contains("$")`
— which binds to a grapheme-aware Foundation substring search
(`StringProtocol.contains<A> → range<A>`; per the Mac trace and the
reviewer's Linux-baseline disassembly — review F3 correction; this
screening doc originally mis-described it as a Character-by-Character
walk) → `run.text.utf8.contains(36)` (byte-level; 0x24 is
self-synchronizing in UTF-8). Equivalence (invariant framing, no identical-
admission assumption across platforms): every old search flavor needs the
0x24 byte, so byte absence rejects exactly what any old guard rejected; and
any run whose Characters contain no bare "$" (e.g. every "$" fused into a
larger Character — GB9b after a Prepend scalar, or combining marks) makes
`split()` a value-preserving no-op returning one value-equal run — parse
output identical for all inputs on every platform regardless of admission
divergence (probe record: checks/guard-admission-probe-record.md).

Motivation: round-17's pure cold find-bar attribution (21,222 samples) puts
1,199 samples (5.65%) inclusively on backtraces carrying the splitInline
closure and 1,163 (5.48%) on `StringProtocol.contains` leaf-ward of it,
although the bench corpus contains NO literal math — the cost is the guard
searching every run of every entry to find nothing. (The round-17 report's
"795 samples (~3.7%)" was an accounting-bucket figure whose generating
invocation was not archived and is not reproducible from the trace — review
F1; corrected to the inclusive counts defined and re-computed in
round-19/attr/inclusive-recount-r19.py.)

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
The Mac gain (-5.75%) is CONSISTENT with the inclusive attribution share
(5.65% closure / 5.48% contains beneath). The screening-time claim that the
gain "exceeds" a ~3.7% estimate is WITHDRAWN (review F1: the estimate was
not reproducible, and comparing sample shares with elapsed-time improvement
cannot establish a per-byte cost claim — any such mechanism reading stays
HYPOTHESIS). No harness artifacts this round: binaries ran in place
(round-18 lesson), all equivalence outputs non-empty.
