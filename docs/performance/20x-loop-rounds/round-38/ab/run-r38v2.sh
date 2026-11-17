#!/bin/bash
# Round 38 v2 Linux formal A/B (screening side): narrative tool-resolution
# memo WITH per-entry language validation (review F1 closure). candidate =
# 4adc09f4 (v2 = v1 80969b9d + language token + pin language leg; PRODUCT
# bytes changed -> full re-run per protocol). base = 6ac65f9 (round-37
# evaluation merge). PRIMARY metric = chain_total; older_page and the rest
# are guards. Equal 4-decimal print on BOTH sides — no fixture patch.
# Adoption rides on Mac; Linux classifies direction + guards. Receipts
# retain porcelain PATH LISTS (round-23 F11).
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=4adc09f4
BASESHA=6ac65f9
MAIN=/home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
cd "$MAIN"
out=.local/round38
mkdir -p "$out/ab38v2"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
git status --porcelain > "$out/ab38v2/main-porcelain-paths.txt"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r38v2-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks38v2"
echo "=== build baseline (PRISTINE $BASESHA; tree kept alive) $(date) ==="
rm -rf /tmp/r38v2-ab-base
git worktree add --detach /tmp/r38v2-ab-base "$BASESHA" >/dev/null 2>&1
(cd /tmp/r38v2-ab-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r38v2-ab-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks38v2"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks38v2" > "$out/ab38v2/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab38v2/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab38v2/checks-cand.log")"
"$out/base-checks38v2" > "$out/ab38v2/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab38v2/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab38v2/checks-base.log")"
grep -h 'prefix cache' "$out/ab38v2/checks-cand.log"
sha256sum "$out/base-checks38v2" "$out/cand-checks38v2" | tee "$out/ab38v2/binary-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock PresentationBench; do
  git show "$BASESHA":Tests/WorkbenchCoreTests/$f.swift 2>/dev/null | sha256sum | sed "s|-|base:Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab38v2/fixture-hashes.txt"
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift 2>/dev/null | sha256sum | sed "s|-|cand:Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab38v2/fixture-hashes.txt"
done
cat "$out/ab38v2/fixture-hashes.txt"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks38v2"
    [ "$variant" = candidate ] && bin="$out/cand-checks38v2"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab38v2/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks38v2" "$out/cand-checks38v2" | tee "$out/ab38v2/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) with retained receipts $(date) ==="
R="$out/ab38v2/rebuild-receipt.txt"
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > "$out/ab38v2/candidate-rebuild.log" 2>&1; cand_rebuild_exit=$?
echo "candidate_rebuild_exit=$cand_rebuild_exit" | tee "$R"
echo "candidate_rebuild_head=$(git rev-parse HEAD)" >> "$R"
echo "candidate_rebuild_porcelain=$(git status --porcelain | wc -l | tr -d ' ')" >> "$R"
git status --porcelain >> "$R"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
rm -rf /tmp/r38v2-ab-base/.build
(cd /tmp/r38v2-ab-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
# note: the patch survives (git checkout state untouched by rm -rf .build)
echo "baseline_rebuild_head=$(git -C /tmp/r38v2-ab-base rev-parse HEAD)" >> "$R"
echo "baseline_rebuild_porcelain=$(git -C /tmp/r38v2-ab-base status --porcelain | wc -l | tr -d ' ')" >> "$R"
git -C /tmp/r38v2-ab-base status --porcelain >> "$R"
sha256sum /tmp/r38v2-ab-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
cp /tmp/r38v2-ab-base/rebuild.log "$out/ab38v2/baseline-rebuild.log"
cat "$R"
git worktree remove --force /tmp/r38v2-ab-base
echo "DONE $(date)"
