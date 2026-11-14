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
clusters, leading/trailing separators, CJK), 60,000 seeded fuzz strings, and a
0…40-byte boundary grid with separators at word edges (cross-word carry).

Timing (SwiftPM release, 9 alternating blocks, rotating inputs, hash-consumed;
ms/call medians):

| platform | input | v0 | v1 | v2 |
| --- | --- | --- | --- | --- |
| Mac mini (arm64) | 9.9KB | 0.004074 | +100.3% | **-69.2%** (blocks 0.00124–0.00130, stable) |
| Mac mini (arm64) | 1.2KB | 0.000485 | +100.9% | **-66.8%** |
| Linux (x86-64) | 9.9KB | 0.006310 | +4.2% | -20.8% |
| Linux (x86-64) | 1.2KB | 0.000790 | +4.1% | -19.4% |

Decision: v1 discarded; v2 opened round 15.

**Post-round addendum (in-context divergence):** adopted on the Mac six-pair
A/B (edit_stats -39.01/-39.46/-42.13%, all pairs separated). Linux in-context
six-pair A/B regressed +27.78% uniformly on edit_stats and +22…+54% on
lineCount-dominated edit-lines rows, while the identical isolated screening on
Linux showed -20.8%. The regression localizes to the rewritten function in the
Linux product-build context; mechanism unresolved (codegen/inlining-context
interaction — inference; no instruction-level forensics, adoption platform
decisive and positive). Lesson recorded in the INDEX negative list: isolated
microbenchmarks do not extrapolate in EITHER direction (round 13: attributed
self-time did not convert; round 15: isolated win inverted in context on one
platform) — mechanical candidates must be screened IN CONTEXT (bench modes)
on both platforms before a round opens.
