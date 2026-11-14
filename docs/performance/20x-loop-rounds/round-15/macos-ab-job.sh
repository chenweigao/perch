#!/bin/bash
# Round 15 Mac mini A/B (decides adoption): baseline = 9c12eb9 + new tests,
# candidate = + SWAR lineCount patch. Both check runs must pass fully
# (Mac runs math: 97 PASS expected, exit 0). Primary: edit_stats@6400/1280/320.
# Context: isolated Mac screening showed -69% for the scan; Linux in-context
# smoke shows +28% on edit_stats@6400 — this A/B is the in-context Mac verdict.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/ab15"
mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 9c12eb9
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round14-baseline .build/round14-candidate .build/round15-profile
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift
echo "=== apply tests patch + baseline build $(date) ==="
git apply "$LOGS/round15-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round15-baseline > "$RES/baseline-build.log" 2>&1
echo "baseline_build_exit=$?"
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/round15-product.patch" && echo product_patch=ok
git status --porcelain
swift build -c release --product WorkbenchChecks --scratch-path .build/round15-candidate > "$RES/candidate-build.log" 2>&1
echo "candidate_build_exit=$?"
baseline=.build/round15-baseline/out/Products/Release/WorkbenchChecks
candidate=.build/round15-candidate/out/Products/Release/WorkbenchChecks
shasum -a 256 "$baseline" "$candidate" | tee "$RES/binary-hashes.txt"
echo "=== check suites $(date) ==="
"$baseline" > "$RES/checks-baseline.log" 2>&1
echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-baseline.log")"
"$candidate" > "$RES/checks-candidate.log" 2>&1
echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-candidate.log")"
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
rm -f Tests/WorkbenchCoreTests/LineCountScanTests.swift
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
