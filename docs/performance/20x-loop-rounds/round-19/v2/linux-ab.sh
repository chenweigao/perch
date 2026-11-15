#!/bin/bash
# Round 19 v2 Linux screening A/B (rerun at 1f9b5d4 after review F1/F2/F3
# moved product-comment and pin bytes). Harness rules: the checks binary
# embeds #filePath, so build trees stay alive while checks run, and the
# rebuild verification happens at the SAME path. Candidate builds in the main
# worktree (HEAD=1f9b5d4, porcelain 0 = committed tree); baseline in a
# scratch worktree kept alive through its check run. Per review F7, this run
# RETAINS full rebuild receipts (digests, exits, source-state, rebuild logs)
# for both sides before the scratch tree is removed.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=1f9b5d4
MAIN=<worktree>
cd "$MAIN"
out=.local/round19
mkdir -p "$out/ab19v2"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r19v2-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks19v2"
echo "=== build baseline (89e5976 + $FINAL tests; tree kept alive) $(date) ==="
rm -rf /tmp/r19v2-base
git worktree add --detach /tmp/r19v2-base 89e5976 >/dev/null 2>&1
git -C /tmp/r19v2-base checkout "$FINAL" -- Tests/
(cd /tmp/r19v2-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r19v2-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks19v2"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks19v2" > "$out/ab19v2/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab19v2/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab19v2/checks-cand.log")"
"$out/base-checks19v2" > "$out/ab19v2/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab19v2/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab19v2/checks-base.log")"
grep -E 'link detection|splitInline|delimiter' "$out/ab19v2/checks-base.log" "$out/ab19v2/checks-cand.log"
sha256sum "$out/base-checks19v2" "$out/cand-checks19v2" | tee "$out/ab19v2/binary-hashes.txt"
git show "$FINAL":Tests/WorkbenchCoreTests/PresentationBench.swift | sha256sum | sed 's|-|Tests/WorkbenchCoreTests/PresentationBench.swift|' > "$out/ab19v2/fixture-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock LinkScanMaterializeTests; do
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift | sha256sum | sed "s|-|Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab19v2/fixture-hashes.txt"
done
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks19v2"
    [ "$variant" = candidate ] && bin="$out/cand-checks19v2"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab19v2/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks19v2" "$out/cand-checks19v2" | tee "$out/ab19v2/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) with retained receipts $(date) ==="
R="$out/ab19v2/rebuild-receipt.txt"
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > "$out/ab19v2/candidate-rebuild.log" 2>&1; cand_rebuild_exit=$?
echo "candidate_rebuild_exit=$cand_rebuild_exit" | tee "$R"
echo "candidate_rebuild_head=$(git rev-parse HEAD)" >> "$R"
echo "candidate_rebuild_porcelain=$(git status --porcelain | wc -l | tr -d ' ')" >> "$R"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
rm -rf /tmp/r19v2-base/.build
(cd /tmp/r19v2-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
echo "baseline_rebuild_head=$(git -C /tmp/r19v2-base rev-parse HEAD)" >> "$R"
echo "baseline_rebuild_porcelain=$(git -C /tmp/r19v2-base status --porcelain | wc -l | tr -d ' ')" >> "$R"
git -C /tmp/r19v2-base status --porcelain >> "$R"
sha256sum /tmp/r19v2-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
cp /tmp/r19v2-base/rebuild.log "$out/ab19v2/baseline-rebuild.log"
cat "$R"
git worktree remove --force /tmp/r19v2-base
echo "DONE $(date)"
