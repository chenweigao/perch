#!/bin/bash
# Round-27 Mac screening (arbitration side): cross-instance rendered-source cache.
# base = PRISTINE ed98b97 (tests patch cannot compile on base — references the new
# public type; disclosed asymmetry). candidate = d191e9c tree. Gain metric computed
# WITHIN the candidate binary (reopen vs cold, same-run); cold base-vs-cand = the
# no-regression guard (~1100ms metric, layout noise negligible). Binaries IN PLACE.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261116"
RES="$LOGS/screen27"
rm -rf "$RES"; mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach ed98b97
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round27-base .build/round27-cand
echo "=== base build (pristine) $(date) ==="
swift build -c release --product WorkbenchChecks --scratch-path .build/round27-base > "$RES/base-build.log" 2>&1
base_build_exit=$?; echo "base_build_exit=$base_build_exit"
[ "$base_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
echo "=== apply patches + candidate build $(date) ==="
git apply "$LOGS/r27-tests.patch" && echo tests_patch=ok
git apply "$LOGS/r27-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round27-cand > "$RES/cand-build.log" 2>&1
cand_build_exit=$?; echo "cand_build_exit=$cand_build_exit"
[ "$cand_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
BASE="$PWD/.build/round27-base/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round27-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND"
echo "=== checks: base (old pin set, record) + candidate (gates) $(date) ==="
"$BASE" > "$RES/checks-base.log" 2>&1; base_checks_exit=$?
echo "base_checks_exit=$base_checks_exit pass=$(grep -c '^PASS' "$RES/checks-base.log")"
"$CAND" > "$RES/checks-cand.log" 2>&1; cand_checks_exit=$?
echo "cand_checks_exit=$cand_checks_exit pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'rendered-source cache' "$RES/checks-cand.log"
[ "$base_checks_exit" = 0 ] && [ "$cand_checks_exit" = 0 ] || { echo ABORT_CHECKS; echo "DONE $(date)"; exit 1; }
echo "=== in-context screening: 3 alternating, streaming + mode 1 (in place) $(date) ==="
for it in 1 2 3; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    WORKBENCH_BENCH=streaming "$side" > "$RES/s-$it-$tag.log" 2>&1; echo "it=$it side=$tag s_exit=$?"
    WORKBENCH_BENCH=1 "$side" > "$RES/c-$it-$tag.log" 2>&1; echo "it=$it side=$tag c_exit=$?"
    fbq=$(grep -o 'find_bar_query_update *median_ms= *[0-9.]*' "$RES/s-$it-$tag.log" | grep -o '[0-9.]*$')
    fbc=$(grep -o 'find_bar_cold_query *median_ms= *[0-9.]*' "$RES/s-$it-$tag.log" | grep -o '[0-9.]*$')
    fbr=$(grep -o 'find_bar_reopen_query *median_ms= *[0-9.]*' "$RES/s-$it-$tag.log" | grep -o '[0-9.]*$')
    sn=$(grep -E "^[[:space:]]+narrative[[:space:]]" "$RES/s-$it-$tag.log" | head -1 | awk '{print $NF}')
    c2=$(grep 'source_slots=2000' "$RES/c-$it-$tag.log" | grep -o 'cold_median_ms=[0-9.]*' | cut -d= -f2)
    op=$(grep -o 'older_page_full_chain *median_ms= *[0-9.]*' "$RES/c-$it-$tag.log" | grep -o '[0-9.]*$')
    echo "it=$it side=$tag query_update=$fbq cold=$fbc reopen=${fbr:-NA} stream_narrative=$sn cold@2000=$c2 older_page=$op"
  done
done
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round27-base .build/round27-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
