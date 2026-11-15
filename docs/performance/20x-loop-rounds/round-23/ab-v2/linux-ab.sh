#!/bin/bash
# Round 23 v2 Linux formal A/B: fullLineDiff byte-range comparison, product=3ba1f1a unchanged, tests=8465aea (review F4/F10 pin strengthening) vs
# base b11a7d5 + pins (round-19 v2 harness template with retained receipts).
# Harness rules: the checks binary embeds #filePath, so build trees stay alive
# while checks run, and rebuild verification happens at the SAME path.
# Candidate builds in the main worktree (HEAD=3ba1f1a); baseline in a scratch
# worktree kept alive through its check run. Per round-22 F7 protocol, full
# rebuild receipts are RETAINED for both sides.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=8465aea
MAIN=<worktree>
cd "$MAIN"
out=.local/round23
mkdir -p "$out/ab23v2"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r23v2-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks23v2"
echo "=== build baseline (b11a7d5 + $FINAL tests; tree kept alive) $(date) ==="
rm -rf /tmp/r23v2-base
git worktree add --detach /tmp/r23v2-base b11a7d5 >/dev/null 2>&1
git -C /tmp/r23v2-base checkout "$FINAL" -- Tests/
(cd /tmp/r23v2-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r23v2-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks23v2"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks23v2" > "$out/ab23v2/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab23v2/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab23v2/checks-cand.log")"
"$out/base-checks23v2" > "$out/ab23v2/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab23v2/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab23v2/checks-base.log")"
grep -E 'edit-line byte-range|link detection' "$out/ab23v2/checks-base.log" "$out/ab23v2/checks-cand.log"
sha256sum "$out/base-checks23v2" "$out/cand-checks23v2" | tee "$out/ab23v2/binary-hashes.txt"
git show "$FINAL":Tests/WorkbenchCoreTests/PresentationBench.swift | sha256sum | sed 's|-|Tests/WorkbenchCoreTests/PresentationBench.swift|' > "$out/ab23v2/fixture-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock LinkScanMaterializeTests; do
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift | sha256sum | sed "s|-|Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab23v2/fixture-hashes.txt"
done
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks23v2"
    [ "$variant" = candidate ] && bin="$out/cand-checks23v2"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab23v2/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks23v2" "$out/cand-checks23v2" | tee "$out/ab23v2/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) with retained receipts $(date) ==="
R="$out/ab23v2/rebuild-receipt.txt"
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > "$out/ab23v2/candidate-rebuild.log" 2>&1; cand_rebuild_exit=$?
echo "candidate_rebuild_exit=$cand_rebuild_exit" | tee "$R"
echo "candidate_rebuild_head=$(git rev-parse HEAD)" >> "$R"
echo "candidate_rebuild_porcelain=$(git status --porcelain | wc -l | tr -d ' ')" >> "$R"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
rm -rf /tmp/r23v2-base/.build
(cd /tmp/r23v2-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
echo "baseline_rebuild_head=$(git -C /tmp/r23v2-base rev-parse HEAD)" >> "$R"
echo "baseline_rebuild_porcelain=$(git -C /tmp/r23v2-base status --porcelain | wc -l | tr -d ' ')" >> "$R"
git -C /tmp/r23v2-base status --porcelain >> "$R"
sha256sum /tmp/r23v2-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
cp /tmp/r23v2-base/rebuild.log "$out/ab23v2/baseline-rebuild.log"
cat "$R"
git worktree remove --force /tmp/r23v2-base
echo "DONE $(date)"
