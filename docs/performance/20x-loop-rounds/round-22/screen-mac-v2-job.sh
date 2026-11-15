#!/bin/bash
# Round-22 v2 Mac screening (compat-fix e14c25d, decides adoption): phase single-pass scan + CJK-compat legacy routing.
# base = ed53341 + pin (r22v2-tests.patch); candidate = + product patch
# (e2ff3c0). In-context bench modes, 3 alternating iterations, binaries run
# IN PLACE (round-18 lesson). Checks double as golden re-verification and
# the Mac-side first run of the exhaustive scalar sweep + differential.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/screen22b"
rm -rf "$RES"; mkdir -p "$RES"
git fetch origin
git checkout --detach ed53341
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
git apply "$LOGS/r22v2-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round22v2-base > "$RES/base-build.log" 2>&1
echo "base_build_exit=$?"
git apply "$LOGS/r22v2-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round22v2-cand > "$RES/cand-build.log" 2>&1
echo "cand_build_exit=$?"
BASE="$PWD/.build/round22v2-base/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round22v2-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND"
echo "=== checks + golden verification ==="
"$BASE" > "$RES/checks-base.log" 2>&1; echo "base_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-base.log")"
grep -h 'narrative byte-keyed' "$RES/checks-base.log"
"$CAND" > "$RES/checks-cand.log" 2>&1; echo "cand_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'narrative byte-keyed' "$RES/checks-cand.log"
echo "=== in-context screening: 3 alternating, presentation-token + streaming + mode 1 (in place) $(date) ==="
for it in 1 2 3; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    WORKBENCH_BENCH=presentation-token "$side" > "$RES/p-$it-$tag.log" 2>&1
    WORKBENCH_BENCH=streaming "$side" > "$RES/s-$it-$tag.log" 2>&1
    WORKBENCH_BENCH=1 "$side" > "$RES/c-$it-$tag.log" 2>&1
    python3 - "$RES/p-$it-$tag.log" "$tag" "$it" <<'PYEOF'
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
    sn=$(grep -E "^[[:space:]]+narrative[[:space:]]" "$RES/s-$it-$tag.log" | head -1 | awk '{print $NF}')
    c2=$(grep 'source_slots=2000' "$RES/c-$it-$tag.log" | grep -o 'cold_median_ms=[0-9.]*' | cut -d= -f2)
    echo "it=$it side=$tag stream_narrative=$sn cold@2000=$c2"
  done
done
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round22v2-base .build/round22v2-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
