#!/bin/bash
# Round 33 Linux formal A/B (screening side): empty-suffix concat guard
# candidate 69094ed (v4 = review F1-F3/N1 closure; product bytes unchanged since afd99aa).
# REVIEW F1: the BASE side gets a print-precision-only fixture patch (4-decimal
# reopen print) so the classifier compares equal-precision samples; patched
# fixture hash is the disclosed receipt. Product tree on base stays pristine. vs base 4c184e5 (merged round-32;
# both sides equal precision (round-33 F1 rule)).
# BOTH trees compile standalone (candidate tests reference ConversationPrefixCache,
# base tests reference only round-30 types) — no asymmetry disclosure needed this
# round: the base bench is the round-30 shape (reopen = per-entry shared path).
# Adoption rides on Mac; Linux classifies direction + guards.
# Receipts retain porcelain PATH LISTS (round-23 F11 protocol).
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=0581fea
BASESHA=529d41e
MAIN=/home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
cd "$MAIN"
out=.local/round35
mkdir -p "$out/ab35v2"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
git status --porcelain > "$out/ab35v2/main-porcelain-paths.txt"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r35v2-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks35v2"
echo "=== build baseline (PRISTINE $BASESHA; tree kept alive) $(date) ==="
rm -rf /tmp/r35v2-ab-base
git worktree add --detach /tmp/r35v2-ab-base "$BASESHA" >/dev/null 2>&1
(cd /tmp/r35v2-ab-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r35v2-ab-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks35v2"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks35v2" > "$out/ab35v2/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab35v2/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab35v2/checks-cand.log")"
"$out/base-checks35v2" > "$out/ab35v2/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab35v2/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab35v2/checks-base.log")"
grep -h 'prefix cache' "$out/ab35v2/checks-cand.log"
sha256sum "$out/base-checks35v2" "$out/cand-checks35v2" | tee "$out/ab35v2/binary-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock PresentationBench; do
  git show "$BASESHA":Tests/WorkbenchCoreTests/$f.swift 2>/dev/null | sha256sum | sed "s|-|base:Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab35v2/fixture-hashes.txt"
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift 2>/dev/null | sha256sum | sed "s|-|cand:Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab35v2/fixture-hashes.txt"
done
cat "$out/ab35v2/fixture-hashes.txt"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks35v2"
    [ "$variant" = candidate ] && bin="$out/cand-checks35v2"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab35v2/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks35v2" "$out/cand-checks35v2" | tee "$out/ab35v2/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) with retained receipts $(date) ==="
R="$out/ab35v2/rebuild-receipt.txt"
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > "$out/ab35v2/candidate-rebuild.log" 2>&1; cand_rebuild_exit=$?
echo "candidate_rebuild_exit=$cand_rebuild_exit" | tee "$R"
echo "candidate_rebuild_head=$(git rev-parse HEAD)" >> "$R"
echo "candidate_rebuild_porcelain=$(git status --porcelain | wc -l | tr -d ' ')" >> "$R"
git status --porcelain >> "$R"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
rm -rf /tmp/r35v2-ab-base/.build
(cd /tmp/r35v2-ab-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
# note: the patch survives (git checkout state untouched by rm -rf .build)
echo "baseline_rebuild_head=$(git -C /tmp/r35v2-ab-base rev-parse HEAD)" >> "$R"
echo "baseline_rebuild_porcelain=$(git -C /tmp/r35v2-ab-base status --porcelain | wc -l | tr -d ' ')" >> "$R"
git -C /tmp/r35v2-ab-base status --porcelain >> "$R"
sha256sum /tmp/r35v2-ab-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
cp /tmp/r35v2-ab-base/rebuild.log "$out/ab35v2/baseline-rebuild.log"
cat "$R"
git worktree remove --force /tmp/r35v2-ab-base
echo "DONE $(date)"
