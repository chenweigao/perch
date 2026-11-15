#!/bin/bash
# Round 24 Mac mini formal A/B (no-regression gate; arbitrates): collapsedWhitespace
# pinned fusion set. base = 1bcbc00 + r24 tests patch (tests-aligned layout; base
# checks EXPECTED to trap on the zero-gap assertion = gap evidence, recorded not
# gated); candidate = + product patch (172fd87). Round-16 gated template otherwise.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/ab24"
rm -rf "$RES"; mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 1bcbc00
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round24-baseline .build/round24-candidate
echo "=== apply tests patch + baseline build $(date) ==="
git apply "$LOGS/r24-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round24-baseline > "$RES/baseline-build.log" 2>&1
baseline_build_exit=$?
echo "baseline_build_exit=$baseline_build_exit"
[ "$baseline_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/r24-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round24-candidate > "$RES/candidate-build.log" 2>&1
candidate_build_exit=$?
echo "candidate_build_exit=$candidate_build_exit"
[ "$candidate_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
baseline=.build/round24-baseline/out/Products/Release/WorkbenchChecks
candidate=.build/round24-candidate/out/Products/Release/WorkbenchChecks
shasum -a 256 "$baseline" "$candidate" | tee "$RES/binary-hashes.txt"
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift Tests/WorkbenchCoreTests/LinkScanMaterializeTests.swift > "$RES/fixture-hashes.txt"
echo "=== check suites: baseline trap EXPECTED (gap evidence), candidate gates $(date) ==="
"$baseline" > "$RES/checks-baseline.log" 2>&1
baseline_checks_exit=$?
echo "baseline_checks_exit=$baseline_checks_exit (EXPECTED nonzero: unfixed product violates the zero-gap assertion) pass_before_trap=$(grep -c '^PASS' "$RES/checks-baseline.log")"
grep -a 'MISMATCH' "$RES/checks-baseline.log" | head -3
"$candidate" > "$RES/checks-candidate.log" 2>&1
candidate_checks_exit=$?
echo "candidate_checks_exit=$candidate_checks_exit pass=$(grep -c '^PASS' "$RES/checks-candidate.log")"
grep -h 'whitespace-adjacent walk\|fast-path fuzz' "$RES/checks-candidate.log"
[ "$candidate_checks_exit" = 0 ] || { echo ABORT_CHECKS; echo "DONE $(date)"; exit 1; }
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
rm -rf .build/round24-baseline .build/round24-candidate
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
