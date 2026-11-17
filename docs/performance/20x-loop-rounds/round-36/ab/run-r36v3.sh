#!/bin/bash
# Round 36 v3 Linux formal A/B (screening side): joined foldParents COW
# adoption. candidate = 1226a2f8 (v3 = v2 + splitAt=2 merge fixture
# strengthening; TEST bytes moved -> full re-run per protocol; product
# bytes identical to v1/v2). base = fd79884 (merged round-35; equal
# 4-decimal reopen print on BOTH sides — no fixture patch needed).
# Adoption rides on Mac; Linux classifies direction + guards. Receipts
# retain porcelain PATH LISTS (round-23 F11).
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=1226a2f8
BASESHA=fd79884
MAIN=/home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
cd "$MAIN"
out=.local/round36
mkdir -p "$out/ab36v3"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
git status --porcelain > "$out/ab36v3/main-porcelain-paths.txt"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r36v3-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks36v3"
echo "=== build baseline (PRISTINE $BASESHA; tree kept alive) $(date) ==="
rm -rf /tmp/r36v3-ab-base
git worktree add --detach /tmp/r36v3-ab-base "$BASESHA" >/dev/null 2>&1
(cd /tmp/r36v3-ab-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r36v3-ab-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks36v3"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks36v3" > "$out/ab36v3/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab36v3/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab36v3/checks-cand.log")"
"$out/base-checks36v3" > "$out/ab36v3/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab36v3/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab36v3/checks-base.log")"
grep -h 'prefix cache' "$out/ab36v3/checks-cand.log"
sha256sum "$out/base-checks36v3" "$out/cand-checks36v3" | tee "$out/ab36v3/binary-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock PresentationBench; do
  git show "$BASESHA":Tests/WorkbenchCoreTests/$f.swift 2>/dev/null | sha256sum | sed "s|-|base:Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab36v3/fixture-hashes.txt"
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift 2>/dev/null | sha256sum | sed "s|-|cand:Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab36v3/fixture-hashes.txt"
done
cat "$out/ab36v3/fixture-hashes.txt"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks36v3"
    [ "$variant" = candidate ] && bin="$out/cand-checks36v3"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab36v3/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks36v3" "$out/cand-checks36v3" | tee "$out/ab36v3/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) with retained receipts $(date) ==="
R="$out/ab36v3/rebuild-receipt.txt"
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > "$out/ab36v3/candidate-rebuild.log" 2>&1; cand_rebuild_exit=$?
echo "candidate_rebuild_exit=$cand_rebuild_exit" | tee "$R"
echo "candidate_rebuild_head=$(git rev-parse HEAD)" >> "$R"
echo "candidate_rebuild_porcelain=$(git status --porcelain | wc -l | tr -d ' ')" >> "$R"
git status --porcelain >> "$R"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
rm -rf /tmp/r36v3-ab-base/.build
(cd /tmp/r36v3-ab-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
# note: the patch survives (git checkout state untouched by rm -rf .build)
echo "baseline_rebuild_head=$(git -C /tmp/r36v3-ab-base rev-parse HEAD)" >> "$R"
echo "baseline_rebuild_porcelain=$(git -C /tmp/r36v3-ab-base status --porcelain | wc -l | tr -d ' ')" >> "$R"
git -C /tmp/r36v3-ab-base status --porcelain >> "$R"
sha256sum /tmp/r36v3-ab-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
cp /tmp/r36v3-ab-base/rebuild.log "$out/ab36v3/baseline-rebuild.log"
cat "$R"
git worktree remove --force /tmp/r36v3-ab-base
echo "DONE $(date)"
