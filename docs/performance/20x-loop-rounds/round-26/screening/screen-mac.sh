#!/bin/bash
# Round-26 Mac screening (decides adoption direction): narrative delimiter byte scan.
# base = 668ec61 + tests patch (differential pin passes on base by design);
# candidate = + product patch (77157a9). Tests-aligned both sides (round-24 lesson).
# In-context bench modes, 3 alternating iterations, binaries IN PLACE (round-18).
# Driver metric lines print 6 decimals (round-25 F2 lesson: no rounded intermediates).
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261116"
RES="$LOGS/screen26"
rm -rf "$RES"; mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 668ec61
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round26-base .build/round26-cand
echo "=== apply tests patch + base build $(date) ==="
mkdir -p "$LOGS"
git apply "$LOGS/r26-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round26-base > "$RES/base-build.log" 2>&1
base_build_exit=$?; echo "base_build_exit=$base_build_exit"
[ "$base_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/r26-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round26-cand > "$RES/cand-build.log" 2>&1
cand_build_exit=$?; echo "cand_build_exit=$cand_build_exit"
[ "$cand_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
BASE="$PWD/.build/round26-base/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round26-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND"
echo "=== checks both sides (differential pin: base must also pass) $(date) ==="
"$BASE" > "$RES/checks-base.log" 2>&1; base_checks_exit=$?
echo "base_checks_exit=$base_checks_exit pass=$(grep -c '^PASS' "$RES/checks-base.log")"
"$CAND" > "$RES/checks-cand.log" 2>&1; cand_checks_exit=$?
echo "cand_checks_exit=$cand_checks_exit pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'delimiter scan' "$RES/checks-base.log" "$RES/checks-cand.log"
[ "$base_checks_exit" = 0 ] && [ "$cand_checks_exit" = 0 ] || { echo ABORT_CHECKS; echo "DONE $(date)"; exit 1; }
echo "=== in-context screening: 3 alternating, presentation-token + streaming + mode 1 (in place) $(date) ==="
for it in 1 2 3; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    WORKBENCH_BENCH=presentation-token "$side" > "$RES/p-$it-$tag.log" 2>&1; echo "it=$it side=$tag p_exit=$?"
    WORKBENCH_BENCH=streaming "$side" > "$RES/s-$it-$tag.log" 2>&1; echo "it=$it side=$tag s_exit=$?"
    WORKBENCH_BENCH=1 "$side" > "$RES/c-$it-$tag.log" 2>&1; echo "it=$it side=$tag c_exit=$?"
    python3 - "$RES/p-$it-$tag.log" "$tag" "$it" <<'PYEOF'
import json, statistics, sys
text = open(sys.argv[1]).read()
doc = json.loads(text[text.index('{'):])
for r in doc["results"]:
    t = r["fixture_turns"]
    prefix = "longtail" if r.get("scenario") == "long-tail-stream" else "token"
    for field in ("narrative_ms", "total_ms"):
        vals = [s[field] for s in r["samples"]]
        print(f"{prefix}{t}_{field}={statistics.median(vals):.6f}", end="  ")
print(f"[it={sys.argv[3]} side={sys.argv[2]}]")
PYEOF
    sn=$(grep -E "^[[:space:]]+narrative[[:space:]]" "$RES/s-$it-$tag.log" | head -1 | awk '{print $NF}')
    c2=$(grep 'source_slots=2000' "$RES/c-$it-$tag.log" | grep -o 'cold_median_ms=[0-9.]*' | cut -d= -f2)
    echo "it=$it side=$tag stream_narrative=$sn cold@2000=$c2"
  done
done
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round26-base .build/round26-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
