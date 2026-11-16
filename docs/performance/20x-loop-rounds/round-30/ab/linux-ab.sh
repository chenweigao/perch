#!/bin/bash
# Round 30 Linux formal A/B: cross-instance verified entry cache (8732e11) vs
# PRISTINE base 4f90b88 (tests reference the new public type — disclosed asymmetry,
# round-27 pattern). Adoption rides on cold+reopen magnitudes; guards classified.
# Receipts retain porcelain PATH LISTS (round-23 F11 protocol).
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=8732e11
BASESHA=4f90b88
MAIN=<worktree>
cd "$MAIN"
out=.local/round30
mkdir -p "$out/ab30"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
git status --porcelain > "$out/ab30/main-porcelain-paths.txt"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r30-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks30"
echo "=== build baseline (PRISTINE $BASESHA; tree kept alive) $(date) ==="
rm -rf /tmp/r30-ab-base
git worktree add --detach /tmp/r30-ab-base "$BASESHA" >/dev/null 2>&1
(cd /tmp/r30-ab-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r30-ab-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks30"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks30" > "$out/ab30/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab30/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab30/checks-cand.log")"
"$out/base-checks30" > "$out/ab30/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab30/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab30/checks-base.log")"
grep -h 'rendered-source cache' "$out/ab30/checks-cand.log"
sha256sum "$out/base-checks30" "$out/cand-checks30" | tee "$out/ab30/binary-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock PresentationBench; do
  git show "$BASESHA":Tests/WorkbenchCoreTests/$f.swift 2>/dev/null | sha256sum | sed "s|-|base:Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab30/fixture-hashes.txt"
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift 2>/dev/null | sha256sum | sed "s|-|cand:Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab30/fixture-hashes.txt"
done
cat "$out/ab30/fixture-hashes.txt"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks30"
    [ "$variant" = candidate ] && bin="$out/cand-checks30"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab30/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks30" "$out/cand-checks30" | tee "$out/ab30/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) with retained receipts $(date) ==="
R="$out/ab30/rebuild-receipt.txt"
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > "$out/ab30/candidate-rebuild.log" 2>&1; cand_rebuild_exit=$?
echo "candidate_rebuild_exit=$cand_rebuild_exit" | tee "$R"
echo "candidate_rebuild_head=$(git rev-parse HEAD)" >> "$R"
echo "candidate_rebuild_porcelain=$(git status --porcelain | wc -l | tr -d ' ')" >> "$R"
git status --porcelain >> "$R"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
rm -rf /tmp/r30-ab-base/.build
(cd /tmp/r30-ab-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
echo "baseline_rebuild_head=$(git -C /tmp/r30-ab-base rev-parse HEAD)" >> "$R"
echo "baseline_rebuild_porcelain=$(git -C /tmp/r30-ab-base status --porcelain | wc -l | tr -d ' ')" >> "$R"
git -C /tmp/r30-ab-base status --porcelain >> "$R"
sha256sum /tmp/r30-ab-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
cp /tmp/r30-ab-base/rebuild.log "$out/ab30/baseline-rebuild.log"
cat "$R"
git worktree remove --force /tmp/r30-ab-base
echo "DONE $(date)"
