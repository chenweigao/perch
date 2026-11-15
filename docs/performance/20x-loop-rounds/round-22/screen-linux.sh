#!/bin/bash
# Round-22 Linux screening: phase single-pass scan (e2ff3c0) vs base
# ed53341 + pin (r22 tests state). Primary metrics: longtail200_narrative/
# total; guards: token200/2000, streaming narrative, cold@2000.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
MAIN=<worktree>
cd "$MAIN"
RES=.local/round22/screen-linux
rm -rf "$RES"; mkdir -p "$RES"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
swift build -c release --product WorkbenchChecks > /tmp/r22-screen-cand-build.log 2>&1; echo "cand_build_exit=$?"
CAND="$PWD/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks"
git worktree remove --force /tmp/r22-screen-base >/dev/null 2>&1; rm -rf /tmp/r22-screen-base; git worktree prune
git worktree add --detach /tmp/r22-screen-base ed53341 >/dev/null 2>&1 || { echo WORKTREE_FAIL; exit 1; }
(cd /tmp/r22-screen-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "base_build_exit=$?")
BASE=/tmp/r22-screen-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
sha256sum "$BASE" "$CAND"
echo "=== screening: 3 alternating, presentation-token + streaming + mode 1 $(date) ==="
for it in 1 2 3; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    WORKBENCH_BENCH=presentation-token "$side" > "$RES/p-$it-$tag.log" 2>&1
    WORKBENCH_BENCH=streaming "$side" > "$RES/s-$it-$tag.log" 2>&1
    WORKBENCH_BENCH=1 "$side" > "$RES/c-$it-$tag.log" 2>&1
    python3 -I - "$RES/p-$it-$tag.log" "$tag" "$it" <<'PYEOF'
import json, statistics, sys
text = open(sys.argv[1]).read()
doc = json.loads(text[text.index('{'):])
for r in doc["results"]:
    t = r["fixture_turns"]
    prefix = "longtail" if r.get("scenario") == "long-tail-stream" else "token"
    for field in ("narrative_ms", "total_ms"):
        vals = [s[field] for s in r["samples"]]
        print(f"{prefix}{t}_{field}={statistics.median(vals):.4f}", end="  ")
print(f"[it={sys.argv[3]} side={sys.argv[2]}]")
PYEOF
    sn=$(grep -E "^\s+narrative\s" "$RES/s-$it-$tag.log" | head -1 | awk '{print $NF}')
    c2=$(grep 'source_slots=2000' "$RES/c-$it-$tag.log" | grep -o 'cold_median_ms=[0-9.]*' | cut -d= -f2)
    echo "it=$it side=$tag stream_narrative=$sn cold@2000=$c2"
  done
done
git worktree remove --force /tmp/r22-screen-base
echo "DONE $(date)"
