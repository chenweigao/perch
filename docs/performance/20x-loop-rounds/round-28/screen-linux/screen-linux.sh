#!/bin/bash
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
cd "$MAIN"
RES=.local/round28/screen-quick
rm -rf "$RES"; mkdir -p "$RES"
echo "HEAD_main=$(git rev-parse HEAD) porcelain=$(git status --porcelain | wc -l | tr -d ' ')"
CAND="$PWD/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks"
git worktree remove --force /tmp/r28-screen-base >/dev/null 2>&1; rm -rf /tmp/r28-screen-base; git worktree prune
git worktree add --detach /tmp/r28-screen-base b89851f >/dev/null 2>&1
(cd /tmp/r28-screen-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "base_build=$?")
BASE=/tmp/r28-screen-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
for it in 1 2; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    for mode in activity streaming 1; do
      WORKBENCH_BENCH=$mode "$side" > "$RES/$it-$tag-$mode.log" 2>&1
      echo "it=$it $tag mode=$mode exit=$?"
    done
    # key lines
    grep -E 'activity_init@|single_turn_activity@|edit_stats@' "$RES/$it-$tag-activity.log" | head -6
    grep -E 'conversation_activity|chain_total' "$RES/$it-$tag-streaming.log" | head -3
    grep -E 'source_slots' "$RES/$it-$tag-1.log" | head -4
  done
done
git worktree remove --force /tmp/r28-screen-base
echo DONE
