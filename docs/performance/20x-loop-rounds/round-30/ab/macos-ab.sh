#!/bin/bash
# Round 30 Mac mini formal A/B (decides adoption): cross-instance verified entry
# cache. base = PRISTINE 4f90b88 (the new tests reference the new public type
# ConversationEntryCache and cannot compile on base — disclosed asymmetry, round-27
# pattern). candidate = 4f90b88 + r30 patches (= 8732e11 tree). Adoption rides on
# find_bar_cold_query + find_bar_reopen_query (BOTH paired — base emits reopen since
# round-27; 46ms-vs-213ms and 334-vs-324ms magnitudes where bench-byte layout noise
# is negligible); us/ms-scale paired metrics are guards under the spread classifier.
# Six alternating pairs x five modes, binaries IN PLACE (round-18). Gated template.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261116"
RES="$LOGS/ab30"
rm -rf "$RES"; mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 4f90b88
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
git status --porcelain > "$RES/pre-porcelain-paths.txt"
rm -rf .build/round30-ab-base .build/round30-ab-cand
echo "=== base build (pristine) $(date) ==="
swift build -c release --product WorkbenchChecks --scratch-path .build/round30-ab-base > "$RES/base-build.log" 2>&1
base_build_exit=$?; echo "base_build_exit=$base_build_exit"
[ "$base_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift Tests/WorkbenchCoreTests/LinkScanMaterializeTests.swift > "$RES/fixture-hashes-base.txt"
echo "=== apply v2 patches + candidate build $(date) ==="
git apply "$LOGS/r30-tests.patch" && echo tests_patch=ok
git apply "$LOGS/r30-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round30-ab-cand > "$RES/cand-build.log" 2>&1
cand_build_exit=$?; echo "cand_build_exit=$cand_build_exit"
[ "$cand_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/BenchClock.swift Tests/WorkbenchCoreTests/LinkScanMaterializeTests.swift > "$RES/fixture-hashes-cand.txt"
BASE="$PWD/.build/round30-ab-base/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round30-ab-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND" | tee "$RES/binary-hashes.txt"
echo "=== checks both sides (base = old pin set, record; cand = gate) $(date) ==="
"$BASE" > "$RES/checks-base.log" 2>&1; base_checks_exit=$?
echo "base_checks_exit=$base_checks_exit pass=$(grep -c '^PASS' "$RES/checks-base.log")"
"$CAND" > "$RES/checks-cand.log" 2>&1; cand_checks_exit=$?
echo "cand_checks_exit=$cand_checks_exit pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'rendered-source cache' "$RES/checks-cand.log"
[ "$base_checks_exit" = 0 ] && [ "$cand_checks_exit" = 0 ] || { echo ABORT_CHECKS; echo "DONE $(date)"; exit 1; }
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$BASE"
    [ "$variant" = candidate ] && bin="$CAND"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$RES/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
shasum -a 256 "$BASE" "$CAND" | tee "$RES/binary-hashes-final.txt"
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round30-ab-base .build/round30-ab-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
