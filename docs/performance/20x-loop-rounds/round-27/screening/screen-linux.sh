#!/bin/bash
# Round-27 Linux screening: cross-instance rendered-source cache (d191e9c) vs base ed98b97.
# Baseline = PRISTINE tree (the tests patch references the new public type and cannot
# compile on base) — disclosed asymmetry; the GAIN metric is computed WITHIN the
# candidate binary (find_bar_reopen_query vs find_bar_cold_query, same binary same run,
# immune to layout confound); cold base-vs-cand serves as the no-regression guard on a
# ~350ms metric where layout noise is negligible (round-25's us-scale lesson n/a).
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
cd "$MAIN"
RES=.local/round27/screen-linux
rm -rf "$RES"; mkdir -p "$RES"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
swift build -c release --product WorkbenchChecks > /tmp/r27-screen-cand-build.log 2>&1; echo "cand_build_exit=$?"
CAND="$PWD/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks"
git worktree remove --force /tmp/r27-screen-base >/dev/null 2>&1; rm -rf /tmp/r27-screen-base; git worktree prune
git worktree add --detach /tmp/r27-screen-base ed98b97 >/dev/null 2>&1 || { echo WORKTREE_FAIL; exit 1; }
(cd /tmp/r27-screen-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "base_build_exit=$?")
BASE=/tmp/r27-screen-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
sha256sum "$BASE" "$CAND"
echo "=== screening: 3 alternating, streaming + mode 1 $(date) ==="
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
git worktree remove --force /tmp/r27-screen-base
echo "DONE $(date)"
