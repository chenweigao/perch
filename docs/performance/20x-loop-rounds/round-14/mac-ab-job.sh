#!/bin/bash
# Round 14 Mac mini A/B (decides adoption): baseline = origin/main (6c8241c),
# candidate = + tools-only projection exit patch, two independent scratch
# product paths, six alternating pairs over the five bench modes.
# BOTH check runs must pass fully (Mac runs math: 96 PASS expected, exit 0).
# Primary metrics: single_turn_activity@2000/@400, activity_init@N;
# guards: everything else including the whole streaming chain.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261114"
RES="$LOGS/ab14"
mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 6c8241c
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round13-baseline .build/round13-candidate
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift
echo "=== apply tests patch + baseline build $(date) ==="
git apply "$LOGS/round14-tests.patch" && echo tests_patch=ok
git status --porcelain
swift build -c release --product WorkbenchChecks --scratch-path .build/round14-baseline > "$RES/baseline-build.log" 2>&1
echo "baseline_build_exit=$?"
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/round14-product.patch" && echo product_patch=ok
git status --porcelain
swift build -c release --product WorkbenchChecks --scratch-path .build/round14-candidate > "$RES/candidate-build.log" 2>&1
echo "candidate_build_exit=$?"
baseline=.build/round14-baseline/out/Products/Release/WorkbenchChecks
candidate=.build/round14-candidate/out/Products/Release/WorkbenchChecks
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
rm -f Tests/WorkbenchCoreTests/ActivityToolsProjectionTests.swift
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
