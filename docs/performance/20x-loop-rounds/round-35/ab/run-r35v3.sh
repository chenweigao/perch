#!/bin/bash
# Round 35 v3 Linux formal A/B (screening side): prepend-aware incremental
# global indexes. candidate = 740b5f2e (v3: v2 + observed-term restore in
# incremental prefixIdentities + projection-level consumed-term kill pin).
# base = 529d41e (merged round-34; equal 4-decimal reopen print on BOTH
# sides — no fixture patch needed). Adoption rides on Mac; Linux classifies
# direction + guards. Receipts retain porcelain PATH LISTS (round-23 F11).
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=740b5f2e
BASESHA=529d41e
MAIN=/home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
cd "$MAIN"
out=.local/round35
mkdir -p "$out/ab35v3"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
git status --porcelain > "$out/ab35v3/main-porcelain-paths.txt"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r35v3-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks35v3"
echo "=== build baseline (PRISTINE $BASESHA; tree kept alive) $(date) ==="
rm -rf /tmp/r35v3-ab-base
git worktree add --detach /tmp/r35v3-ab-base "$BASESHA" >/dev/null 2>&1
(cd /tmp/r35v3-ab-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r35v3-ab-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks35v3"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks35v3" > "$out/ab35v3/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab35v3/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab35v3/checks-cand.log")"
"$out/base-checks35v3" > "$out/ab35v3/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab35v3/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab35v3/checks-base.log")"
grep -h 'prefix cache' "$out/ab35v3/checks-cand.log"
sha256sum "$out/base-checks35v3" "$out/cand-checks35v3" | tee "$out/ab35v3/binary-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock PresentationBench; do
  git show "$BASESHA":Tests/WorkbenchCoreTests/$f.swift 2>/dev/null | sha256sum | sed "s|-|base:Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab35v3/fixture-hashes.txt"
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift 2>/dev/null | sha256sum | sed "s|-|cand:Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab35v3/fixture-hashes.txt"
done
cat "$out/ab35v3/fixture-hashes.txt"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks35v3"
    [ "$variant" = candidate ] && bin="$out/cand-checks35v3"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab35v3/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks35v3" "$out/cand-checks35v3" | tee "$out/ab35v3/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) with retained receipts $(date) ==="
R="$out/ab35v3/rebuild-receipt.txt"
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > "$out/ab35v3/candidate-rebuild.log" 2>&1; cand_rebuild_exit=$?
echo "candidate_rebuild_exit=$cand_rebuild_exit" | tee "$R"
echo "candidate_rebuild_head=$(git rev-parse HEAD)" >> "$R"
echo "candidate_rebuild_porcelain=$(git status --porcelain | wc -l | tr -d ' ')" >> "$R"
git status --porcelain >> "$R"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
rm -rf /tmp/r35v3-ab-base/.build
(cd /tmp/r35v3-ab-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
# note: the patch survives (git checkout state untouched by rm -rf .build)
echo "baseline_rebuild_head=$(git -C /tmp/r35v3-ab-base rev-parse HEAD)" >> "$R"
echo "baseline_rebuild_porcelain=$(git -C /tmp/r35v3-ab-base status --porcelain | wc -l | tr -d ' ')" >> "$R"
git -C /tmp/r35v3-ab-base status --porcelain >> "$R"
sha256sum /tmp/r35v3-ab-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks >> "$R"
cp /tmp/r35v3-ab-base/rebuild.log "$out/ab35v3/baseline-rebuild.log"
cat "$R"
git worktree remove --force /tmp/r35v3-ab-base
echo "DONE $(date)"
