#!/bin/bash
# Round 12 Mac mini A/B RE-RUN at the review-fixed head (23bebb2, Codex P2:
# encoding-exact query cache keys): matched baseline (base product + new tests)
# and fixed candidate in two independent scratch product paths, six alternating
# pairs over the five bench modes.
# The baseline check run is EXPECTED to fail (nonzero exit) at the prefix
# zero-sign flip transition — the pre-existing Earlier canonical-value window
# reuse serving stale "-0" hits, the hole the rendered-identity fix closes
# (round-11-style documented expected failure, 12 PASS before it).
# The candidate must pass fully (Mac runs math: 94 PASS, exit 0).
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261114"
RES="$LOGS/ab12c"
mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 7d5ba26
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift
echo "=== apply tests patch + baseline build $(date) ==="
git apply "$LOGS/round12-tests-v3.patch" && echo tests_patch=ok
git status --porcelain
swift build -c release --product WorkbenchChecks --scratch-path .build/round12-baseline-v3 > "$RES/baseline-build.log" 2>&1
echo "baseline_build_exit=$?"
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/round12-product-v3.patch" && echo product_patch=ok
git status --porcelain
swift build -c release --product WorkbenchChecks --scratch-path .build/round12-candidate-v3 > "$RES/candidate-build.log" 2>&1
echo "candidate_build_exit=$?"
baseline=.build/round12-baseline-v3/out/Products/Release/WorkbenchChecks
candidate=.build/round12-candidate-v3/out/Products/Release/WorkbenchChecks
shasum -a 256 "$baseline" "$candidate" | tee "$RES/binary-hashes.txt"
echo "=== check suites $(date) ==="
"$baseline" > "$RES/checks-baseline.log" 2>&1
echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-baseline.log")"
grep -n "SearchEntryReuseTests.swift" "$RES/checks-baseline.log" | head -3
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
# The tests patch adds one new untracked file; remove it so the tree returns
# to pristine (round-12 first-run lesson: checkout -- . keeps untracked files).
git checkout -- .
rm -f Tests/WorkbenchCoreTests/SearchEntryReuseTests.swift
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
