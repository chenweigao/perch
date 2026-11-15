#!/bin/bash
# Round-19 Mac screening: splitInline byte guard. base = 89e5976 (product ==
# 3a711f9), baseline side = base + pin (PENDING golden), candidate = + guard.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/screen19"
rm -rf "$RES"; mkdir -p "$RES"
git fetch origin
git checkout --detach 89e5976
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
git apply "$LOGS/r19-tests-pending.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round19-base > "$RES/base-build.log" 2>&1
echo "base_build_exit=$?"
git apply "$LOGS/r19-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round19-cand > "$RES/cand-build.log" 2>&1
echo "cand_build_exit=$?"
BASE="$PWD/.build/round19-base/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round19-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND"
echo "=== checks + golden capture ==="
"$BASE" > "$RES/checks-base.log" 2>&1; echo "base_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-base.log")"
grep -h 'GOLDEN_CAPTURE split-inline' "$RES/checks-base.log"
"$CAND" > "$RES/checks-cand.log" 2>&1; echo "cand_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'GOLDEN_CAPTURE split-inline' "$RES/checks-cand.log"
echo "=== in-context screening: 3 alternating, streaming + mode 1 (in place) $(date) ==="
for it in 1 2 3; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    WORKBENCH_BENCH=streaming "$side" > "$RES/s-$it-$tag.log" 2>&1
    WORKBENCH_BENCH=1 "$side" > "$RES/c-$it-$tag.log" 2>&1
    fb=$(grep 'find_bar_cold_query' "$RES/s-$it-$tag.log" | awk '{print $NF}')
    c2=$(grep 'source_slots=2000' "$RES/c-$it-$tag.log" | grep -o 'cold_median_ms=[0-9.]*' | cut -d= -f2)
    echo "it=$it side=$tag find_bar_cold=$fb cold@2000=$c2"
  done
done
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round19-base .build/round19-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
