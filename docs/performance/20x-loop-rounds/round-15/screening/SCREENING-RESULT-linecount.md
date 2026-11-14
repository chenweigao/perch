# Round-15 screening (Mac mini + Linux, 2026-11-14) — lineCount SWAR scan PASSED screening, adopted on Mac, with a disclosed Linux in-context regression

Candidate: replace `SessionEditStats.lineCount`'s scalar byte loop (predicate
`bytes[i]==0x0A && bytes[i-1]!=0x0D`, non-vectorizable) with equivalent
formulations. Contract: separators = LF-not-after-CR = (all LF) − (adjacent
CR-LF pairs).

Variants (package `linecount-screen-Package.swift` + `…-main.swift`, run log
`linecount-screen-run-mac.log`):
- v0 = verbatim product scan
- v1 = split predicates (count all LF; count CRLF pairs; subtract) — scalar
- v2 = SWAR: 8-byte words, has-zero bit trick for 0x0A/0x0D, popcount, CR mask
  shifted one byte for in-word pairs, cross-word carry flag, scalar tail

Equivalence: PASS — three-way (v0/v1/v2) over 22 fixed cases (CRLF/CR/LF
clusters, leading/trailing separators, CJK), 60,000 seeded fuzz strings, and
an eleven-length boundary selection through 65 bytes with separators at word
edges (the full 0…40 grid lives in the product pin, not this screen). NOTE:
none of these alphabets contained VT (0x0B) or FF (0x0C) — see addendum 2 for
the mask bug that family exposed.

Timing (SwiftPM release, 9 alternating blocks, rotating inputs, hash-consumed;
ms/call medians):

| platform | input | v0 | v1 | v2 |
| --- | --- | --- | --- | --- |
| Mac mini (arm64) | 9.9KB | 0.004074 | +100.3% | **-69.2%** (blocks 0.00124–0.00130, stable) |
| Mac mini (arm64) | 1.2KB | 0.000485 | +100.9% | **-66.8%** |
| Linux (x86-64) | 9.9KB | 0.006310 | +4.2% | -20.8% |
| Linux (x86-64) | 1.2KB | 0.000790 | +4.1% | -19.4% |

Decision: v1 discarded; v2 opened round 15.

**Addendum 2 (review B1 — correctness bug in the screened v2):** the screened
v2 used the classic subtraction has-zero form `((x−0x01…) & ~x & 0x80…)`, whose
per-byte marking is inexact under borrow propagation (a 0x01 byte after a zero
byte gets falsely marked): LF+VT and CR+FF adjacencies corrupted the masks (the
review's counterexamples: `"\n\u{000B}aaaaaa"` → 3 vs 2 lines;
`"\r\u{000C}\naaaaa"` and `"aaaaaa\r\u{000C}\naaaaaaa"` → 1 vs 2). The
screening corpus (no VT/FF bytes) could not expose it and the initial product
pin shared the gap. The shipped implementation uses the carry-free exact form
`~(((x&0x7F…)+0x7F…) | x | 0x7F…)` (one extra OR per word); the pin gained the
counterexamples, VT/FF in both alphabets, and family-coverage guards (27,885
cases: 22,302 containing VT/FF bytes and — via a dedicated counter added at the
re-review, which found the original label overstated presence as adjacency —
16,811 with an LF→VT or CR→FF adjacency; demonstrated red on the unfixed build,
green after). Timing direction is unaffected (one extra OR per word); the v2
A/B at the fixed head is the authoritative adoption measurement. Also (review
NB4): screen v2 wrapped the scan in a local String copy + `withUTF8` while the
product uses `withContiguousStorageIfAvailable` — the shared part is the
arithmetic, not the wrapper. Linux raw screening log: 
`linecount-screen-run-linux.log` (re-run reproduces -20.7%/-19.5%, within
0.1pp of the original -20.8%/-19.4%).

**Post-round addendum (in-context divergence; localization corrected per review B3):** adopted on the Mac six-pair
A/B (edit_stats -39.01/-39.46/-42.13%, all pairs separated). Linux in-context
six-pair A/B regressed uniformly on edit_stats (+27.78% at the pre-fix head,
+31.1~+32.1% at the fixed head) and +22…+54% on the edit-lines rows, while the
identical isolated screening on Linux showed -20.8%. CORRECTED localization
(review B3): the ordinary edit-lines rows do NOT call lineCount (unchanged
fullLineDiff path) and match the round-8 Linux layout-swing family; the
edit_stats regression is consistent with in-context lineCount cost in aggregate
per-turn framing (the initial per-call normalization ignored the fixture's
Edit calls). Both explanations are inference; mechanism unresolved; no
instruction-level forensics (adoption platform decisive and positive; the
review explicitly does not block on Linux forensics). Lesson recorded in the INDEX negative list: isolated
microbenchmarks do not extrapolate in EITHER direction (round 13: attributed
self-time did not convert; round 15: isolated win inverted in context on one
platform) — mechanical candidates must be screened IN CONTEXT (bench modes)
on both platforms before a round opens.
