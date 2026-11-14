#!/bin/bash
# Round 15 Linux A/B: baseline = 9c12eb9 product, candidate = + SWAR lineCount.
# Both check suites must pass fully (96 PASS + 1 SKIP, exit 0).
# NOTE: smoke showed a consistent in-context edit_stats regression (+28%) on
# Linux despite -20.8% isolated screening; the six pairs record it formally.
set -u
cd <worktree>
out=.local/round15
mkdir -p "$out/ab-v2"
sha256sum Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift Tests/WorkbenchCoreTests/LineCountScanTests.swift > "$out/ab-v2/fixture-hashes.txt"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks"
    [ "$variant" = candidate ] && bin="$out/cand-checks"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab-v2/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks" "$out/cand-checks" | tee "$out/ab-v2/binary-hashes-final.txt"
echo "DONE $(date)"
