# Round-15 screening (Mac mini, 2026-11-14) — collapsedWhitespace byte-path rewrite REJECTED before round start

Candidate: rewrite the round-11 byte path internals with identical semantics —
(v1a) `(0x09...0x0D).contains` protocol-witness calls → direct comparisons,
(v1b) per-byte ASCII `out.append` → bulk `append(contentsOf:)` of ASCII runs,
(v1c) `isNonASCIIWhitespace` guard `scalar <= 0x3000` fast reject,
(v1d) `isPrependScalar` block quick-reject table derived from the pinned set.

Motivation: cold-profile at 9c12eb9 still shows collapsedWhitespace at 24.4%
with leaves `RangeExpression.contains` witness 1.85%, `Array.append` 1.44%,
`isPrependScalar` 1.35%, `isNonASCIIWhitespace` 1.06%, closure body 7.42%.

Equivalence: PASS — three-way differential (v0 verbatim product copy, v1
rewrite, strict split/join oracle) over 35 fixed edge cases (Prepend scalars
incl. U+0600/U+111C2/U+111C3/U+113D1/U+16D43, non-ASCII whitespace, ZWJ,
combining marks after space, CRLF, exotic spaces) + 40,000 seeded fuzz cases.
Zero mismatches. Design was sound; performance is not.

Timing (SwiftPM release on the mini, 9 alternating blocks × 20,000 calls,
64 rotating excerpt-shaped CJK/English-mixed inputs ~1,464 bytes,
hash-consumed outputs; ms per call, medians):

    v0 = 0.002834   v1 = 0.003304   change = +16.56% SLOWER
    per-block: +15.3 +15.1 +14.8 +15.1 +16.1 +14.9 +24.1 +10.5 +13.0 (9/9 blocks)

Mechanism hypotheses (inference, not verified): `append(contentsOf:)` over
`UnsafeBufferPointer` slices carries generic Sequence/slice dispatch that costs
more than the reserved-capacity per-byte appends it replaces for the short runs
in mixed text; the run-scan adds a second pass over ASCII bytes (scan, then
copy) versus the single-pass original; the block table adds an indirection
where the compiler already reduced the pinned switch to efficient comparisons.
This mirrors the round-13 lesson: attributed self-time share does not guarantee
convertibility — the optimizer's existing codegen for these "inefficiencies" is
better than the hand-rewrite.

Decision: do not open round 15 with this candidate; record in the negative
list. Do not retry collapsedWhitespace loop-shape rewrites without new
mechanism-level evidence (e.g., instruction-level comparison showing real
dispatch overhead in the shipped binary). validateUTF8 (4.42%) remains
shelved (no public API bypass, round-11 finding).

Artifacts: screening package `screen/` (Package.swift + main.swift with v0/v1
verbatim), `screen-build.log`, `screen-run.log` (this run), mini location
~/Library/Logs/perf-loop-20261115/r15screen.
