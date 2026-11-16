#!/bin/bash
# Round 26 Mac mini formal A/B (decides adoption): narrative delimiter byte scan.
# base = 668ec61 + tests patch (differential pin passes on base by design);
# candidate = + product patch (77157a9). Tests-aligned both sides (round-24 lesson).
# Six alternating pairs x five modes, binaries IN PLACE (round-18). Gated template.
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261116"
RES="$LOGS/ab26"
rm -rf "$RES"; mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach 668ec61
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round26-baseline .build/round26-cand
echo "=== apply tests patch + base build $(date) ==="
mkdir -p "$LOGS"
git apply "$LOGS/r26-tests.patch" && echo tests_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round26-baseline > "$RES/base-build.log" 2>&1
base_build_exit=$?; echo "base_build_exit=$base_build_exit"
[ "$base_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/r26-product.patch" && echo product_patch=ok
swift build -c release --product WorkbenchChecks --scratch-path .build/round26-cand > "$RES/cand-build.log" 2>&1
cand_build_exit=$?; echo "cand_build_exit=$cand_build_exit"
[ "$cand_build_exit" = 0 ] || { echo ABORT_BUILD; echo "DONE $(date)"; exit 1; }
BASE="$PWD/.build/round26-baseline/out/Products/Release/WorkbenchChecks"
CAND="$PWD/.build/round26-cand/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$BASE" "$CAND" | tee "$RES/binary-hashes.txt"
echo "=== checks both sides (differential pin: base must also pass) $(date) ==="
"$BASE" > "$RES/checks-base.log" 2>&1; base_checks_exit=$?
echo "base_checks_exit=$base_checks_exit pass=$(grep -c '^PASS' "$RES/checks-base.log")"
"$CAND" > "$RES/checks-cand.log" 2>&1; cand_checks_exit=$?
echo "cand_checks_exit=$cand_checks_exit pass=$(grep -c '^PASS' "$RES/checks-cand.log")"
grep -h 'delimiter scan' "$RES/checks-base.log" "$RES/checks-cand.log"
[ "$base_checks_exit" = 0 ] && [ "$cand_checks_exit" = 0 ] || { echo ABORT_CHECKS; echo "DONE $(date)"; exit 1; }
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$BASE"
    [ "$variant" = candidate ] && bin="$CAND"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$RES/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
shasum -a 256 "$BASE" "$CAND" | tee "$RES/binary-hashes-final.txt"
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round26-baseline .build/round26-cand
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
