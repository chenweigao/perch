# Round-12 candidate screening (Mac mini, 2026-11-14) — REJECTED before round start

> **注意：本文件保留原始记录原样；单位标注（µs 实为 ms）、"whole-text" 措辞与
> fuzz 语料归属已由 [ERRATUM.md](ERRATUM.md) 更正，以 erratum 为准。**

Candidate: avoid the prefix(320) grapheme walk / String materialization in
ConversationTurnSummary.excerpt's single-part path via (v1) fused scalar-capped
collapse or (v2) count-first + in-place substring collapse.

Equivalence: 41,092-case differential fuzz vs the current formula — 0 failures
(equivalence-prototype-v2.swift). Design was sound; performance is not.

Screening: SwiftPM release package on the mini (~/Library/Logs/perf-loop-20261113/r12mb),
9 alternating blocks x 20,000 iterations, 64 rotating inputs, hash-consumed results
(anti-hoisting; first interpreter-mode and hoisted runs were discarded as artifacts).
µs/call medians:

  user(337sc,505B CJK):      v0=0.0035  v1=+20.1%  v2=+4.4%
  assistant(368sc,540B CJK): v0=0.0035  v1=+20.7%  v2=+4.9%
  short(14sc):               v0=0.0004  v1=-37.6%  v2=-37.9%
  longAscii(2400sc):         v0=0.0013  v1=+27.8%  v2=+1.8%

Mechanism: v0's prefix(320) truncates ALL downstream collapse work to <=320
characters; v1/v2 pay whole-text (or capped-abort) collapse/count passes on top
of the same grapheme walk for any text >320 scalars — which both fixture texts
are (337/368). The stdlib grapheme walk (~650ns/excerpt in xctrace attribution)
has no cheaper sound substitute: scalar-count bounds only prove prefix==whole
for <=320-scalar texts, and the fixture exceeds that.

Side findings: bare `swiftc` binaries are SIGKILLed on the mini (hello-world
reproduces; SwiftPM-built binaries run fine) — use SwiftPM scratch packages for
any ad-hoc Mac measurement. Interpreter-mode (`swift file.swift`) microbenchmarks
are invalid for this kind of code (stdlib native vs interpreted closures skew).

Decision: do not open round 12 with this candidate; record in the negative list.
Next: re-read attribution for a non-string-mechanism target (TurnSummary.make
refcount traffic 13.4%, TimelineEntry.make 10.4% per-phase KimiMessage rebuilds).
