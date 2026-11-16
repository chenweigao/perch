#!/bin/bash
# Round-28 Mac screening CONTINUATION: the first job died at the checks gate line
# (unbound variable bug after checks PASSED: cand_checks_exit=0 pass=108, SWAR pin
# PASS line present). Binaries from that job are intact — run the pairs on them.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261116"
RES="$LOGS/screen28"
BASE="$PWD/.build/round28-base/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round28-cand/out/Products/Release/WorkbenchChecks"
[ -x "$BASE" ] && [ -x "$CAND" ] || { echo ABORT_MISSING_BINARIES; echo "DONE $(date)"; exit 1; }
echo "=== continuation $(date) ==="
shasum -a 256 "$BASE" "$CAND" | tee "$RES/binary-hashes.txt"
echo "=== screening: 2 alternating pairs, activity/streaming/1 (in place) $(date) ==="
for it in 1 2; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    for mode in activity streaming 1; do
      WORKBENCH_BENCH=$mode "$side" > "$RES/$it-$tag-$mode.log" 2>&1
      echo "it=$it $tag mode=$mode exit=$?"
    done
    grep 'single_turn_calls' "$RES/$it-$tag-activity.log"
    grep -E 'conversation_activity|chain_total' "$RES/$it-$tag-streaming.log" | head -3
    grep 'source_slots=2000' "$RES/$it-$tag-1.log"
  done
done
shasum -a 256 "$BASE" "$CAND" | tee "$RES/binary-hashes-final.txt"
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round28-base .build/round28-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
