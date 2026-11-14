#!/bin/bash
# Round-17 Mac golden capture + in-context screening (streaming & cold modes,
# 3 alternating iterations, base vs candidate).
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/screen17"
rm -rf "$RES"; mkdir -p "$RES"
git fetch origin
git checkout --detach 76940c0
git checkout -- . 2>/dev/null; git clean -fdq Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
git apply "$LOGS/r17-tests-pending.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round17-base > "$RES/base-build.log" 2>&1
echo "base_build_exit=$?"
git apply "$LOGS/r17-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round17-cand > "$RES/cand-build.log" 2>&1
echo "cand_build_exit=$?"
B=.build/round17-base/out/Products/Release/WorkbenchChecks
C=.build/round17-cand/out/Products/Release/WorkbenchChecks
shasum -a 256 "$B" "$C" | tee "$RES/binary-hashes.txt"
"$B" > "$RES/checks-base.log" 2>&1; echo "base_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-base.log")"
"$C" > "$RES/checks-candidate.log" 2>&1; echo "cand_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-candidate.log")"
grep -h GOLDEN_CAPTURE "$RES/checks-base.log" "$RES/checks-candidate.log"
echo "=== in-context screening $(date) ==="
for it in 1 2 3; do
  for side in base cand; do
    bin="$B"; [ "$side" = cand ] && bin="$C"
    WORKBENCH_BENCH=streaming "$bin" > "$RES/screen-$it-$side-streaming.log" 2>&1
    echo "it=$it side=$side streaming exit=$?"
    WORKBENCH_BENCH=1 "$bin" > "$RES/screen-$it-$side-cold.log" 2>&1
    echo "it=$it side=$side cold exit=$?"
  done
done
git checkout -- . ; git clean -fdq Tests/
rm -rf .build/round17-base .build/round17-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
