#!/bin/bash
# Round 22 Linux screening A/B: phase single-pass scan (e2ff3c0) vs base
# ed53341 + pins (round-19 v2 harness template with retained receipts). Harness rules: the checks binary
# embeds #filePath, so build trees stay alive while checks run, and the
# rebuild verification happens at the SAME path. Candidate builds in the main
# worktree (HEAD=e2ff3c0, porcelain 0 = committed tree); baseline in a
# scratch worktree kept alive through its check run. Per review F7, this run
# RETAINS full rebuild receipts (digests, exits, source-state, rebuild logs)
# for both sides before the scratch tree is removed.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=e2ff3c0
MAIN=<worktree>
cd "$MAIN"
out=.local/round22
mkdir -p "$out/ab22"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r22-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks22"
echo "=== build baseline (ed53341 + $FINAL tests; tree kept alive) $(date) ==="
rm -rf /tmp/r22-base
git worktree add --detach /tmp/r22-base ed53341 >/dev/null 2>&1
git -C /tmp/r22-base checkout "$FINAL" -- Tests/
(cd /tmp/r22-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r22-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks22"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks22" > "$out/ab22/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab22/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab22/checks-cand.log")"
"$out/base-checks22" > "$out/ab22/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab22/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab22/checks-base.log")"
grep -E 'link detection|splitInline|delimiter' "$out/ab22/checks-base.log" "$out/ab22/checks-cand.log"
sha256sum "$out/base-checks22" "$out/cand-checks22" | tee "$out/ab22/binary-hashes.txt"
git show "$FINAL":Tests/WorkbenchCoreTests/PresentationBench.swift | sha256sum | sed 's|-|Tests/WorkbenchCoreTests/PresentationBench.swift|' > "$out/ab22/fixture-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock LinkScanMaterializeTests; do
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift | sha256sum | sed "s|-|Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab22/fixture-hashes.txt"
done
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks22"
    [ "$variant" = candidate ] && bin="$out/cand-checks22"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab22/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks22" "$out/cand-checks22" | tee "$out/ab22/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) with retained receipts $(date) ==="
R="$out/ab22/rebuild-receipt.txt"
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > "$out/ab22/candidate-rebuild.log" 2>&1; cand_rebuild_exit=$?
echo "candidate_rebuild_exit=$cand_rebuild_exit" | tee "$R"
echo "candidate_rebuild_head=$(git rev-parse HEAD)" >> "$R"
echo "candidate_rebuild_porcelain=$(git status --porcelain | wc -l | tr -d ' ')" >> "$R"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
rm -rf /tmp/r22-base/.build
(cd /tmp/r22-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
echo "baseline_rebuild_head=$(git -C /tmp/r22-base rev-parse HEAD)" >> "$R"
echo "baseline_rebuild_porcelain=$(git -C /tmp/r22-base status --porcelain | wc -l | tr -d ' ')" >> "$R"
git -C /tmp/r22-base status --porcelain >> "$R"
sha256sum /tmp/r22-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
cp /tmp/r22-base/rebuild.log "$out/ab22/baseline-rebuild.log"
cat "$R"
git worktree remove --force /tmp/r22-base
echo "DONE $(date)"
