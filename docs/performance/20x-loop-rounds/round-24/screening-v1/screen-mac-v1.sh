#!/bin/bash
# Round-24 Mac screening (no-regression gate; decides with Linux): collapsedWhitespace
# pinned fusion set. base = PRISTINE 1bcbc00 (old pin, characterizes the 7 gaps);
# candidate = 1bcbc00 + tests + product patches (172fd87). In-context bench modes
# (presentation-token/streaming/1), 3 alternating iterations, binaries run IN PLACE
# (round-18 lesson). Candidate checks must show 0 fusion gaps and strict-path 2708
# (2701 + pinned 7); baseline checks show the old "7 characterized gaps" line — the
# new pin is a contract assertion the unfixed product intentionally fails.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/screen24b"
rm -rf "$RES"; mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 1bcbc00
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round24b-base .build/round24b-cand
echo "=== apply tests patch + base build (v2 design: BOTH sides carry the tests
# patch so bench-code layout is isolated; the base check run is EXPECTED to trap on
# the zero-gap assertion — that trap is the evidence the unfixed product violates
# the new contract, and it is recorded, not gated on) $(date) ==="
git apply "$LOGS/r24-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round24b-base > "$RES/base-build.log" 2>&1
base_build_exit=$?; echo "base_build_exit=$base_build_exit"
[ "$base_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/r24-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round24b-cand > "$RES/cand-build.log" 2>&1
cand_build_exit=$?; echo "cand_build_exit=$cand_build_exit"
[ "$cand_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
BASE="$PWD/.build/round24b-base/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round24b-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND"
shasum -a 256 Tests/WorkbenchCoreTests/PresentationBench.swift Tests/WorkbenchCoreTests/StreamingBench.swift Tests/WorkbenchCoreTests/BenchClock.swift > "$RES/fixture-hashes.txt"
echo "=== checks: base (EXPECTED trap = gap evidence) + candidate (must pass) $(date) ==="
"$BASE" > "$RES/checks-base.log" 2>&1; base_checks_exit=$?
echo "base_checks_exit=$base_checks_exit (EXPECTED nonzero: unfixed product violates the zero-gap assertion)"
grep -h 'WHITESPACE-ADJACENT MISMATCH' "$RES/checks-base.log" | head -8
grep -c 'WHITESPACE-ADJACENT MISMATCH' "$RES/checks-base.log" | sed 's/^/base_walk_mismatch_lines=/'
"$CAND" > "$RES/checks-cand.log" 2>&1; cand_checks_exit=$?
echo "cand_checks_exit=$cand_checks_exit pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'whitespace-adjacent walk\|fast-path fuzz' "$RES/checks-cand.log"
[ "$cand_checks_exit" = 0 ] || { echo ABORT_CHECKS; echo "DONE $(date)"; exit 1; }
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
        print(f"{prefix}{t}_{field}={statistics.median(vals):.4f}", end="  ")
print(f"[it={sys.argv[3]} side={sys.argv[2]}]")
PYEOF
    sn=$(grep -E "^[[:space:]]+narrative[[:space:]]" "$RES/s-$it-$tag.log" | head -1 | awk '{print $NF}')
    c2=$(grep 'source_slots=2000' "$RES/c-$it-$tag.log" | grep -o 'cold_median_ms=[0-9.]*' | cut -d= -f2)
    fb=$(grep -o 'find_bar_cold_query_median_ms=[0-9.]*' "$RES/s-$it-$tag.log" | head -1 | cut -d= -f2)
    echo "it=$it side=$tag stream_narrative=$sn cold@2000=$c2 find_bar=$fb"
  done
done
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round24b-base .build/round24b-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
