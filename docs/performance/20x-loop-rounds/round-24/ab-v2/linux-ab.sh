#!/bin/bash
# Round 24 v2 Linux formal A/B (no-regression gate; product logic identical to v1, comment+print corrections per review F1/F6): collapsedWhitespace pinned fusion set.
# base = 1bcbc00 + r24 Tests (tests-aligned layout; base checks EXPECTED to trap on the
# zero-gap assertion = gap evidence, recorded not gated); candidate = 172fd87 tree.
# Receipts retained per round-22 F7 protocol; round-24 addition: porcelain PATH LISTS
# retained per review F11 (round-23).
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=c3d38a2
MAIN=<worktree>
cd "$MAIN"
out=.local/round24
mkdir -p "$out/ab24v2"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
git status --porcelain > "$out/ab24v2/main-porcelain-paths.txt"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r24v2-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks24v2"
echo "=== build baseline (1bcbc00 + $FINAL Tests; tree kept alive) $(date) ==="
rm -rf /tmp/r24v2-base
git worktree add --detach /tmp/r24v2-base 1bcbc00 >/dev/null 2>&1
git -C /tmp/r24v2-base checkout "$FINAL" -- Tests/
(cd /tmp/r24v2-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r24v2-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks24v2"
echo "=== checks both sides (base trap EXPECTED = gap evidence; candidate must pass) $(date) ==="
"$out/cand-checks24v2" > "$out/ab24v2/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab24v2/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab24v2/checks-cand.log")"
"$out/base-checks24v2" > "$out/ab24v2/checks-base.log" 2>&1; echo "baseline_checks_exit=$? (EXPECTED nonzero) pass_before_trap=$(grep -c '^PASS' "$out/ab24v2/checks-base.log")"
grep -a 'MISMATCH' "$out/ab24v2/checks-base.log" | head -3
grep -h 'whitespace-adjacent walk\|fast-path fuzz' "$out/ab24v2/checks-cand.log"
sha256sum "$out/base-checks24v2" "$out/cand-checks24v2" | tee "$out/ab24v2/binary-hashes.txt"
git show "$FINAL":Tests/WorkbenchCoreTests/PresentationBench.swift | sha256sum | sed 's|-|Tests/WorkbenchCoreTests/PresentationBench.swift|' > "$out/ab24v2/fixture-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock LinkScanMaterializeTests; do
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift | sha256sum | sed "s|-|Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab24v2/fixture-hashes.txt"
done
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks24v2"
    [ "$variant" = candidate ] && bin="$out/cand-checks24v2"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab24v2/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks24v2" "$out/cand-checks24v2" | tee "$out/ab24v2/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) with retained receipts $(date) ==="
R="$out/ab24v2/rebuild-receipt.txt"
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > "$out/ab24v2/candidate-rebuild.log" 2>&1; cand_rebuild_exit=$?
echo "candidate_rebuild_exit=$cand_rebuild_exit" | tee "$R"
echo "candidate_rebuild_head=$(git rev-parse HEAD)" >> "$R"
echo "candidate_rebuild_porcelain=$(git status --porcelain | wc -l | tr -d ' ')" >> "$R"
git status --porcelain >> "$R"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
rm -rf /tmp/r24v2-base/.build
(cd /tmp/r24v2-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
echo "baseline_rebuild_head=$(git -C /tmp/r24v2-base rev-parse HEAD)" >> "$R"
echo "baseline_rebuild_porcelain=$(git -C /tmp/r24v2-base status --porcelain | wc -l | tr -d ' ')" >> "$R"
git -C /tmp/r24v2-base status --porcelain >> "$R"
sha256sum /tmp/r24v2-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
cp /tmp/r24v2-base/rebuild.log "$out/ab24v2/baseline-rebuild.log"
cat "$R"
git worktree remove --force /tmp/r24v2-base
echo "DONE $(date)"
