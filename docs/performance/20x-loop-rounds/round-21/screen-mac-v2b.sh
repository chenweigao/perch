#!/bin/bash
# Round-21 v2b Mac EXTENDED screening (6 alternating, presentation-token only): byte-keyed narrative tables
# with withUTF8 equality/hashing (v1 per-byte fallbacks gave the saving back).
# base = a559cea + long-tail bench extension (r21-tests.patch = 68b0ce4
# tree); candidate = + byte-key product patch (a7332c8). In-context bench
# modes, 3 alternating iterations, binaries run IN PLACE (round-18 lesson).
# Checks double as golden re-verification at this head pair.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/screen21c"
rm -rf "$RES"; mkdir -p "$RES"
git fetch origin
git checkout --detach a559cea
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
git apply "$LOGS/r21-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round21-base > "$RES/base-build.log" 2>&1
echo "base_build_exit=$?"
git apply "$LOGS/r21v2-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round21-cand > "$RES/cand-build.log" 2>&1
echo "cand_build_exit=$?"
BASE="$PWD/.build/round21-base/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round21-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND"
echo "=== checks + golden verification ==="
"$BASE" > "$RES/checks-base.log" 2>&1; echo "base_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-base.log")"
grep -h 'narrative byte-keyed' "$RES/checks-base.log"
"$CAND" > "$RES/checks-cand.log" 2>&1; echo "cand_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'narrative byte-keyed' "$RES/checks-cand.log"
echo "=== extended screening: 6 alternating, presentation-token only (guards verified twice) $(date) ==="
for it in 1 2 3 4 5 6; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    WORKBENCH_BENCH=presentation-token "$side" > "$RES/p-$it-$tag.log" 2>&1
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
  done
done
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round21-base .build/round21-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
