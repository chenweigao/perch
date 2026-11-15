#!/bin/bash
# Round-23 Linux screening: fullLineDiff byte-range comparison (3ba1f1a) vs base b11a7d5.
# Primary: edit512_{unchanged,middle,insert,first,last,unicode}; watch: edit512_canonical
# (extra failing byte compare before canonical fallback); guards: edit512_bulk (SWAR path
# untouched), edit_stats@*, activity_init, streaming narrative, cold@2000.
# Linux screening does NOT run checks (round-22 F3' receipt discipline).
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
cd "$MAIN"
RES=.local/round23/screen-linux
rm -rf "$RES"; mkdir -p "$RES"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
swift build -c release --product WorkbenchChecks > /tmp/r23-screen-cand-build.log 2>&1; echo "cand_build_exit=$?"
CAND="$PWD/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks"
git worktree remove --force /tmp/r23-screen-base >/dev/null 2>&1; rm -rf /tmp/r23-screen-base; git worktree prune
git worktree add --detach /tmp/r23-screen-base b11a7d5 >/dev/null 2>&1 || { echo WORKTREE_FAIL; exit 1; }
(cd /tmp/r23-screen-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "base_build_exit=$?")
BASE=/tmp/r23-screen-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
sha256sum "$BASE" "$CAND"
echo "=== screening: 3 alternating, edit-lines + activity + streaming + mode 1 $(date) ==="
for it in 1 2 3; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    WORKBENCH_BENCH=edit-lines "$side" > "$RES/e-$it-$tag.log" 2>&1; echo "it=$it side=$tag edit_lines_exit=$?"
    WORKBENCH_BENCH=activity "$side" > "$RES/a-$it-$tag.log" 2>&1; echo "it=$it side=$tag activity_exit=$?"
    WORKBENCH_BENCH=streaming "$side" > "$RES/s-$it-$tag.log" 2>&1; echo "it=$it side=$tag streaming_exit=$?"
    WORKBENCH_BENCH=1 "$side" > "$RES/c-$it-$tag.log" 2>&1; echo "it=$it side=$tag mode1_exit=$?"
    python3 -I - "$RES/e-$it-$tag.log" "$tag" "$it" <<'PYEOF'
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
git worktree remove --force /tmp/r23-screen-base
echo "DONE $(date)"
