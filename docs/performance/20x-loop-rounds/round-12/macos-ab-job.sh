#!/bin/bash
# Round 12 Mac mini A/B (decides adoption): matched baseline (base product + new
# tests) and candidate (base + product patch) in two independent scratch product
# paths, six alternating pairs over the five bench modes.
# Both check runs must pass fully (Mac runs the math checks: 94 PASS expected);
# the new search-reuse check is equivalence-only and passes on the unoptimized
# product as well. Primary metric: streaming find_bar_query_update.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261114"
RES="$LOGS/ab12"
mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 7d5ba26
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
# The attribution capture's scratch build is transient (its binary hash is
# archived in the attr log); free the space before the two A/B builds.
rm -rf .build/round12-profile
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift
echo "=== apply tests patch + baseline build $(date) ==="
git apply "$LOGS/round12-tests.patch" && echo tests_patch=ok
git status --porcelain
swift build -c release --product WorkbenchChecks --scratch-path .build/round12-baseline > "$RES/baseline-build.log" 2>&1
echo "baseline_build_exit=$?"
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/round12-product.patch" && echo product_patch=ok
git status --porcelain
swift build -c release --product WorkbenchChecks --scratch-path .build/round12-candidate > "$RES/candidate-build.log" 2>&1
echo "candidate_build_exit=$?"
baseline=.build/round12-baseline/out/Products/Release/WorkbenchChecks
candidate=.build/round12-candidate/out/Products/Release/WorkbenchChecks
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
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
