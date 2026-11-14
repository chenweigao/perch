#!/bin/bash
# Round 14 Linux screening A/B: baseline = origin/main (6c8241c) product,
# candidate = + tools-only projection exit. BOTH check suites must pass fully
# (95 PASS + 1 SKIP, exit 0) — the differential check uses pre-existing API
# and passes on both sides by design.
set -u
cd <worktree>
out=.local/round14
mkdir -p "$out/ab"
sha256sum Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift Tests/WorkbenchCoreTests/ActivityToolsProjectionTests.swift > "$out/ab/fixture-hashes.txt"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks"
    [ "$variant" = candidate ] && bin="$out/cand-checks"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks" "$out/cand-checks" | tee "$out/ab/binary-hashes-final.txt"
echo "DONE $(date)"
