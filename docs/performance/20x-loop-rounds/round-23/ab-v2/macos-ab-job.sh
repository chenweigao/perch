#!/bin/bash
# Round 23 Mac mini formal A/B (decides adoption): base = b11a7d5 (= main),
# candidate = product 3ba1f1a (unchanged) + tests 8465aea (review F4/F10 pin strengthening). Generated from
# the round-16 gated template. Aborts before pairs if any build/check fails.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/ab23v2"
rm -rf "$RES"; mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach b11a7d5
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round23v2-baseline .build/round23v2-candidate
echo "=== apply tests patch + baseline build $(date) ==="
git apply "$LOGS/r23v2-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round23v2-baseline > "$RES/baseline-build.log" 2>&1
baseline_build_exit=$?
echo "baseline_build_exit=$baseline_build_exit"
[ "$baseline_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/r23v2-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round23v2-candidate > "$RES/candidate-build.log" 2>&1
candidate_build_exit=$?
echo "candidate_build_exit=$candidate_build_exit"
[ "$candidate_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
baseline=.build/round23v2-baseline/out/Products/Release/WorkbenchChecks
candidate=.build/round23v2-candidate/out/Products/Release/WorkbenchChecks
shasum -a 256 "$baseline" "$candidate" | tee "$RES/binary-hashes.txt"
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift Tests/WorkbenchCoreTests/LinkScanMaterializeTests.swift > "$RES/fixture-hashes.txt"
echo "=== check suites $(date) ==="
"$baseline" > "$RES/checks-baseline.log" 2>&1
baseline_checks_exit=$?
echo "baseline_checks_exit=$baseline_checks_exit pass=$(grep -c '^PASS' "$RES/checks-baseline.log")"
"$candidate" > "$RES/checks-candidate.log" 2>&1
candidate_checks_exit=$?
echo "candidate_checks_exit=$candidate_checks_exit pass=$(grep -c '^PASS' "$RES/checks-candidate.log")"
grep -E 'edit-line byte-range' "$RES/checks-baseline.log" "$RES/checks-candidate.log"
if [ "$baseline_checks_exit" != 0 ] || [ "$candidate_checks_exit" != 0 ]; then echo ABORT_CHECKS; echo "DONE $(date)"; exit 1; fi
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$baseline"
    [ "$variant" = candidate ] && bin="$candidate"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$RES/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
shasum -a 256 "$baseline" "$candidate" | tee "$RES/binary-hashes-final.txt"
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round23v2-baseline .build/round23v2-candidate
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
