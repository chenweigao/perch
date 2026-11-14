#!/bin/bash
# Round 18 Mac mini A/B (REJECTION evidence): base = a13aee2, candidate =
# + visible() trimmingCharacters->non-allocating whitespace check. Screening
# showed Mac within noise (-1..-2% vs ~4-5% cold spread) while Linux -55%;
# this formal six-pair run confirms Mac non-separation and checks guardrails
# for regressions (round-10 precedent found a candidate regression).
set -u
cd "$HOME/_worktrees/20x-loop-20261112/perch"
LOGS="$HOME/Library/Logs/perf-loop-20261115"
RES="$LOGS/ab18"
rm -rf "$RES"; mkdir -p "$RES"
echo "=== prepare $(date) ==="
git fetch origin
git checkout --detach a13aee2
git checkout -- . 2>/dev/null; git clean -fdq Sources/ Tests/
echo "HEAD=$(git rev-parse HEAD)"
echo "porcelain_before=$(git status --porcelain | wc -l | tr -d ' ')"
rm -rf .build/round18-baseline .build/round18-candidate
echo "=== baseline build (unmodified) $(date) ==="
swift build -c release --product WorkbenchChecks --scratch-path .build/round18-baseline > "$RES/baseline-build.log" 2>&1
echo "baseline_build_exit=$?"
echo "=== apply product patch + candidate build $(date) ==="
git apply "$LOGS/r18-product.patch" && echo product_patch=ok
git status --porcelain
swift build -c release --product WorkbenchChecks --scratch-path .build/round18-candidate > "$RES/candidate-build.log" 2>&1
echo "candidate_build_exit=$?"
baseline="$PWD/.build/round18-baseline/out/Products/Release/WorkbenchChecks"
candidate="$PWD/.build/round18-candidate/out/Products/Release/WorkbenchChecks"
shasum -a 256 "$baseline" "$candidate" | tee "$RES/binary-hashes.txt"
echo "=== check suites $(date) ==="
"$baseline" > "$RES/checks-baseline.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-baseline.log")"
"$candidate" > "$RES/checks-candidate.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$RES/checks-candidate.log")"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$baseline"; [ "$variant" = candidate ] && bin="$candidate"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$RES/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
shasum -a 256 "$baseline" "$candidate" | tee "$RES/binary-hashes-final.txt"
git checkout -- . ; git clean -fdq Sources/ Tests/
rm -rf .build/round18-baseline .build/round18-candidate
echo "porcelain_after=$(git status --porcelain | wc -l | tr -d ' ')"
echo "DONE $(date)"
