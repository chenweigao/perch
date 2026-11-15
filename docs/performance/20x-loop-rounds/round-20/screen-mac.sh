#!/bin/bash
# Round-20 v2 Mac screening: lean L() resolution chain (CFPreferences
# single-key read + canonical-identifier shortcut + locale table).
# base = c085fd9, baseline side = base + pins, candidate = + Localization patch.
# v1 (byte-keyed tables) was rejected by the first screening; see round-20 report. In-context bench modes, 3 alternating iterations, binaries
# run IN PLACE (round-18 lesson). Checks double as the Mac-side golden
# capture (four-way with the Linux pair).
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/screen20"
rm -rf "$RES"; mkdir -p "$RES"
git fetch origin
git checkout --detach c085fd9
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
git apply "$LOGS/r20v2-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round20-base > "$RES/base-build.log" 2>&1
echo "base_build_exit=$?"
echo "=== localization runtime pins (BASE Localization.swift + new pins; working tree pre-product-patch) ==="
bash scripts/check-localization-runtime.sh > "$RES/l10n-runtime-base.log" 2>&1; echo "l10n_runtime_base_exit=$?"
tail -2 "$RES/l10n-runtime-base.log"
git apply "$LOGS/r20v2-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round20-cand > "$RES/cand-build.log" 2>&1
echo "cand_build_exit=$?"
BASE="$PWD/.build/round20-base/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round20-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND"
echo "=== checks + golden verification ==="
"$BASE" > "$RES/checks-base.log" 2>&1; echo "base_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-base.log")"
grep -h 'narrative byte-keyed' "$RES/checks-base.log"
"$CAND" > "$RES/checks-cand.log" 2>&1; echo "cand_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'narrative byte-keyed' "$RES/checks-cand.log"
echo "=== localization runtime pins (CANDIDATE Localization.swift) ==="
bash scripts/check-localization-runtime.sh > "$RES/l10n-runtime-cand.log" 2>&1; echo "l10n_runtime_cand_exit=$?"
tail -2 "$RES/l10n-runtime-cand.log"
echo "=== in-context screening: 3 alternating, presentation-token + streaming + mode 1 (in place) $(date) ==="
for it in 1 2 3; do
  for side in "$BASE" "$CAND"; do
    tag=base; [ "$side" = "$CAND" ] && tag=cand
    WORKBENCH_BENCH=presentation-token "$side" > "$RES/p-$it-$tag.log" 2>&1
    WORKBENCH_BENCH=streaming "$side" > "$RES/s-$it-$tag.log" 2>&1
    WORKBENCH_BENCH=1 "$side" > "$RES/c-$it-$tag.log" 2>&1
    python3 - "$RES/p-$it-$tag.log" "$tag" "$it" <<'PYEOF'
import json, statistics, sys, re
text = open(sys.argv[1]).read()
doc = json.loads(text[text.index('{'):])
for r in doc["results"]:
    t = r["fixture_turns"]
    for field in ("narrative_ms", "total_ms"):
        vals = [s[field] for s in r["samples"]]
        print(f"token{t}_{field}={statistics.median(vals):.4f}", end="  ")
print(f"[it={sys.argv[3]} side={sys.argv[2]}]")
PYEOF
    sn=$(grep 'stage_narrative' "$RES/s-$it-$tag.log" | awk '{print $NF}')
    c2=$(grep 'source_slots=2000' "$RES/c-$it-$tag.log" | grep -o 'cold_median_ms=[0-9.]*' | cut -d= -f2)
    echo "it=$it side=$tag stage_narrative=$sn cold@2000=$c2"
  done
done
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round20-base .build/round20-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
