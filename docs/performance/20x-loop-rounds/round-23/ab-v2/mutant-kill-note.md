# Mutation-kill evidence (review F4 self-verification)

Mutant: `lineRangesEqual` returns `offset == length` directly for
equal-length ranges (skipping the canonical fallback), applied in a
scratch git worktree at 8465aea (/tmp/r23-mutant, removed after; never
committed anywhere).

Result: WorkbenchChecks exits 132 (SIGILL, Swift precondition failure);
crash frame `checkEditLineByteRangeDiff()` at
Tests/WorkbenchCoreTests/EditLineByteRangeTests.swift:300 — the
zero-mismatch differential precondition. 44 PASS lines precede the trap.
Raw log: mutant-kill-checks.log (this directory).

The reviewer had demonstrated the same mutant passing the v1 corpus
(their mutant-replay.log): every canonical-equal pair in the v1 corpus
differed in byte LENGTH, so the mutant's length-check分流 masked the
missing fallback. The two v2 pairs (U+0340/U+0300; NFC/NFD-swapped
equal-length lines) are same-length byte-differing canonically-equal and
kill the mutant.
