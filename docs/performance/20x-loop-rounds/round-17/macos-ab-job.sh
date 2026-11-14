#!/bin/bash
# Round 16 Mac mini A/B at 413bf86 (pin compile fix; product comment-corrected
# 4f0ea7b + differential pin bcbdd91 lineage). Aborts before pairs if any
# build or check side fails.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/ab17e"
mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 76940c0
git checkout -- . 2>/dev/null; git clean -fdq Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round17-baseline .build/round17-candidate .build/round17-verify2
echo "=== apply tests patch + baseline build $(date) ==="
git apply "$LOGS/r17-tests-final2.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round17-baseline-e > "$RES/baseline-build.log" 2>&1
baseline_build_exit=$?
echo "baseline_build_exit=$baseline_build_exit"
[ "$baseline_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/r17-product-final2.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round17-candidate-e > "$RES/candidate-build.log" 2>&1
candidate_build_exit=$?
echo "candidate_build_exit=$candidate_build_exit"
[ "$candidate_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
baseline=.build/round17-baseline-e/out/Products/Release/WorkbenchChecks
candidate=.build/round17-candidate-e/out/Products/Release/WorkbenchChecks
shasum -a 256 "$baseline" "$candidate" | tee "$RES/binary-hashes.txt"
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift Tests/WorkbenchCoreTests/LinkScanMaterializeTests.swift > "$RES/fixture-hashes.txt"
echo "=== check suites $(date) ==="
"$baseline" > "$RES/checks-baseline.log" 2>&1
baseline_checks_exit=$?
echo "baseline_checks_exit=$baseline_checks_exit pass=$(grep -c '^PASS' "$RES/checks-baseline.log")"
"$candidate" > "$RES/checks-candidate.log" 2>&1
candidate_checks_exit=$?
echo "candidate_checks_exit=$candidate_checks_exit pass=$(grep -c '^PASS' "$RES/checks-candidate.log")"
grep -E 'link detection' "$RES/checks-baseline.log" "$RES/checks-candidate.log"
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
git checkout -- .
git clean -fdq Tests/
rm -rf .build/round17-baseline-e .build/round17-candidate-e
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
