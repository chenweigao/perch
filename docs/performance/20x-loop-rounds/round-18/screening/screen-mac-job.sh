#!/bin/bash
# Round-18 Mac screening (v2): run SwiftPM products IN PLACE (copied binaries
# get SIGKILLed on macOS). base = a13aee2, cand = + visible() whitespace patch.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/screen18b"
rm -rf "$RES"; mkdir -p "$RES"
git fetch origin
git checkout --detach a13aee2
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "=== base build ==="
swift build -c release --product WorkbenchChecks --scratch-path .build/round18-base > "$RES/base-build.log" 2>&1
echo "base_build_exit=$?"
BASE="$PWD/.build/round18-base/out/Products/Release/WorkbenchChecks"
echo "=== apply patch + cand build ==="
git apply "$LOGS/r18-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round18-cand > "$RES/cand-build.log" 2>&1
echo "cand_build_exit=$?"
CAND="$PWD/.build/round18-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND"
echo "=== correctness: mode-1 rows identical? ==="
WORKBENCH_BENCH=1 "$BASE" 2>/dev/null | grep -oE 'source_slots=[0-9]+|cold_rows=[0-9]+|appended_rows=[0-9]+|text_bytes=[0-9]+' > "$RES/base-rows.txt"
WORKBENCH_BENCH=1 "$CAND" 2>/dev/null | grep -oE 'source_slots=[0-9]+|cold_rows=[0-9]+|appended_rows=[0-9]+|text_bytes=[0-9]+' > "$RES/cand-rows.txt"
echo "base-rows lines: $(wc -l < "$RES/base-rows.txt")"
if diff -q "$RES/base-rows.txt" "$RES/cand-rows.txt" >/dev/null && [ -s "$RES/base-rows.txt" ]; then echo "ROWS_IDENTICAL_NONEMPTY"; else echo "ROWS_DIFFER_OR_EMPTY"; fi
echo "=== cold screen: 6 alternating, mode 1, cold@2000 + cold@1000 ==="
for it in 1 2 3 4 5 6; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    WORKBENCH_BENCH=1 "$side" 2>/dev/null | awk -v it="$it" -v tag="$tag" '/source_slots=1000 /{for(i=1;i<=NF;i++)if($i~/^cold_median_ms=/){sub(/cold_median_ms=/,"",$i);print it" "tag" cold@1000="$i}} /source_slots=2000 /{for(i=1;i<=NF;i++)if($i~/^cold_median_ms=/){sub(/cold_median_ms=/,"",$i);print it" "tag" cold@2000="$i}}'
  done
done
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round18-base .build/round18-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
