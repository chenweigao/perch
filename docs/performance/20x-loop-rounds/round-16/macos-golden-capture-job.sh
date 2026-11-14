#!/bin/bash
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/capture16"
mkdir -p "$RES"
git fetch origin
git checkout --detach 15f612f
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
git apply "$LOGS/r16-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round16-base > "$RES/base-build.log" 2>&1
echo "base_build_exit=$?"
.build/round16-base/out/Products/Release/WorkbenchChecks > "$RES/checks-base.log" 2>&1
echo "base_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-base.log")"
grep -E 'GOLDEN_CAPTURE|link detection' "$RES/checks-base.log"
git apply "$LOGS/r16-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round16-cand > "$RES/cand-build.log" 2>&1
echo "cand_build_exit=$?"
.build/round16-cand/out/Products/Release/WorkbenchChecks > "$RES/checks-cand.log" 2>&1
echo "cand_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -E 'GOLDEN_CAPTURE|link detection' "$RES/checks-cand.log"
db=$(grep GOLDEN_CAPTURE "$RES/checks-base.log" | awk '{print $NF}')
dc=$(grep GOLDEN_CAPTURE "$RES/checks-cand.log" | awk '{print $NF}')
echo "base_digest=$db cand_digest=$dc equal=$([ "$db" = "$dc" ] && echo YES || echo NO)"
git checkout -- .
git clean -fdq Tests/
rm -rf .build/round16-base .build/round16-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
