#!/bin/bash
# Round 12 Linux A/B re-run at the review-fixed head (b87488c): matched baseline
# (base product + new tests) and fixed candidate, six alternating pairs.
# The baseline check run is EXPECTED to fail (nonzero exit) in
# checkSearchCacheHoleProbes after 13 PASS: all four pre-existing cache holes
# print their PROBE MISMATCH line first, then the terminal precondition ends
# the run (documented expected failure). The candidate must pass 94 + 1 SKIP,
# exit 0.
set -u
cd <worktree>
out=.local/round12
mkdir -p "$out/ab-v4"
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift Tests/WorkbenchCoreTests/SearchEntryReuseTests.swift > "$out/ab-v4/fixture-hashes.txt" 2>/dev/null \
  || sha256sum Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift Tests/WorkbenchCoreTests/SearchEntryReuseTests.swift > "$out/ab-v4/fixture-hashes.txt"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks-matched-v4"
    [ "$variant" = candidate ] && bin="$out/cand-checks"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab-v4/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks-matched-v4" "$out/cand-checks" | tee "$out/ab-v4/binary-hashes-final.txt"
echo "DONE $(date)"
