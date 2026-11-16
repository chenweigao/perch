#!/bin/bash
# Round-28 Mac in-context screening (queue item ② gate, round-10 lesson, round-25 F1):
# SWAR utf16 count at ConversationActivity sites vs pristine b89851f.
# 2 alternating pairs, modes activity/streaming/1. Target metric:
# single_turn_activity (activity_init_median_ms @ calls=1000) — round-25 F2 sized the
# outputCharacters walk at ~4.5% of it (Linux); Linux quick screen showed +4.7% REGRESSION.
# Mac arbitrates the mixed product shape (stdlib CF-side vs corelibs may differ).
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261116"
RES="$LOGS/screen28"
rm -rf "$RES"; mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach b89851f
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round28-base .build/round28-cand
echo "=== base build (pristine) $(date) ==="
swift build -c release --product WorkbenchChecks --scratch-path .build/round28-base > "$RES/base-build.log" 2>&1
echo "base_build_exit=$?"
BASE="$PWD/.build/round28-base/out/Products/Release/WorkbenchChecks"
[ -x "$BASE" ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
echo "=== apply patches + candidate build $(date) ==="
git apply "$LOGS/r28-tests.patch" && echo tests_patch=ok
git apply "$LOGS/r28-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round28-cand > "$RES/cand-build.log" 2>&1
echo "cand_build_exit=$?"
CAND="$PWD/.build/round28-cand/out/Products/Release/WorkbenchChecks"
[ -x "$CAND" ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
shasum -a 256 "$BASE" "$CAND"
echo "=== checks candidate (gate) $(date) ==="
"$CAND" > "$RES/checks-cand.log" 2>&1; echo "cand_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'SWAR' "$RES/checks-cand.log"
[ "$cand_checks_exit" = 0 ] || { echo ABORT_CHECKS; echo "DONE $(date)"; exit 1; }
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
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round28-base .build/round28-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
