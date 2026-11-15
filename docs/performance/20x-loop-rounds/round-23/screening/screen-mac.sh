#!/bin/bash
# Round-23 Mac screening (decides adoption direction): fullLineDiff byte-range comparison.
# base = b11a7d5 + pin (r23-tests.patch); candidate = + product patch (3ba1f1a).
# In-context bench modes (edit-lines/activity/streaming/1), 3 alternating iterations,
# binaries run IN PLACE (round-18 lesson). Checks double as pin verification on Mac.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/screen23"
rm -rf "$RES"; mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach b11a7d5
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round23-base .build/round23-cand
echo "=== apply tests patch + base build $(date) ==="
git apply "$LOGS/r23-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round23-base > "$RES/base-build.log" 2>&1
base_build_exit=$?; echo "base_build_exit=$base_build_exit"
[ "$base_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/r23-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round23-cand > "$RES/cand-build.log" 2>&1
cand_build_exit=$?; echo "cand_build_exit=$cand_build_exit"
[ "$cand_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
BASE="$PWD/.build/round23-base/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round23-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND"
shasum -a 256 Tests/WorkbenchCoreTests/EditLineBench.swift Tests/WorkbenchCoreTests/ActivityBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/BenchClock.swift > "$RES/fixture-hashes.txt"
echo "=== checks both sides $(date) ==="
"$BASE" > "$RES/checks-base.log" 2>&1; base_checks_exit=$?
echo "base_checks_exit=$base_checks_exit pass=$(grep -c '^PASS' "$RES/checks-base.log")"
"$CAND" > "$RES/checks-cand.log" 2>&1; cand_checks_exit=$?
echo "cand_checks_exit=$cand_checks_exit pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'edit-line byte-range' "$RES/checks-base.log" "$RES/checks-cand.log"
[ "$base_checks_exit" = 0 ] && [ "$cand_checks_exit" = 0 ] || { echo ABORT_CHECKS; echo "DONE $(date)"; exit 1; }
echo "=== in-context screening: 3 alternating, edit-lines + activity + streaming + mode 1 (in place) $(date) ==="
for it in 1 2 3; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    WORKBENCH_BENCH=edit-lines "$side" > "$RES/e-$it-$tag.log" 2>&1; echo "it=$it side=$tag edit_lines_exit=$?"
    WORKBENCH_BENCH=activity "$side" > "$RES/a-$it-$tag.log" 2>&1; echo "it=$it side=$tag activity_exit=$?"
    WORKBENCH_BENCH=streaming "$side" > "$RES/s-$it-$tag.log" 2>&1; echo "it=$it side=$tag streaming_exit=$?"
    WORKBENCH_BENCH=1 "$side" > "$RES/c-$it-$tag.log" 2>&1; echo "it=$it side=$tag mode1_exit=$?"
    python3 - "$RES/e-$it-$tag.log" "$tag" "$it" <<'PYEOF'
import json, sys
text = open(sys.argv[1]).read()
doc = json.loads(text[text.index('{'):])
want = [("unchanged",512),("middle",512),("insert",512),("first",512),("last",512),("unicode",512),("canonical",512),("bulk",512),("middle",64)]
index = {(r["case"], r["source_rows"]): r["median_ms"] for r in doc["results"]}
for case, rows in want:
    print(f"edit{rows}_{case}={index[(case,rows)]:.4f}", end="  ")
print(f"[it={sys.argv[3]} side={sys.argv[2]}]")
PYEOF
    grep -o 'turns=[0-9]* messages=[0-9]* edit_stats_median_ms=[0-9.]*' "$RES/a-$it-$tag.log" | tr '\n' ' '; echo "[activity it=$it side=$tag]"
    sn=$(grep -E "^[[:space:]]+narrative[[:space:]]" "$RES/s-$it-$tag.log" | head -1 | awk '{print $NF}')
    c2=$(grep 'source_slots=2000' "$RES/c-$it-$tag.log" | grep -o 'cold_median_ms=[0-9.]*' | cut -d= -f2)
    echo "it=$it side=$tag stream_narrative=$sn cold@2000=$c2"
  done
done
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round23-base .build/round23-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
