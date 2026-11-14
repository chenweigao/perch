#!/bin/bash
# Round 16 Linux A/B (rerun with fixed harness): the checks binary embeds
# #filePath, so build trees must stay alive while checks run, and the rebuild
# verification must happen at the SAME path. Candidate builds in the main
# worktree (HEAD=9e7bc19, porcelain 0 = committed tree); baseline in a scratch
# worktree kept alive through its check run.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=66a94d5
MAIN=<worktree>
cd "$MAIN"
out=.local/round17
mkdir -p "$out/ab17v3"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r17e-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks17c"
echo "=== build baseline (76940c0 + $FINAL tests; tree kept alive) $(date) ==="
rm -rf /tmp/r17e-base
git worktree add --detach /tmp/r17e-base 76940c0 >/dev/null 2>&1
git -C /tmp/r17e-base checkout "$FINAL" -- Tests/
(cd /tmp/r17e-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r17e-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks17c"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks17c" > "$out/ab17v3/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab17v3/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab17v3/checks-cand.log")"
"$out/base-checks17c" > "$out/ab17v3/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab17v3/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab17v3/checks-base.log")"
grep -E 'link detection' "$out/ab17v3/checks-base.log" "$out/ab17v3/checks-cand.log"
sha256sum "$out/base-checks17c" "$out/cand-checks17c" | tee "$out/ab17v3/binary-hashes.txt"
git show "$FINAL":Tests/WorkbenchCoreTests/PresentationBench.swift | sha256sum | sed 's|-|Tests/WorkbenchCoreTests/PresentationBench.swift|' > "$out/ab17v3/fixture-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock LinkScanMaterializeTests; do
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift | sha256sum | sed "s|-|Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab17v3/fixture-hashes.txt"
done
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks17c"
    [ "$variant" = candidate ] && bin="$out/cand-checks17c"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab17v3/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks17c" "$out/cand-checks17c" | tee "$out/ab17v3/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) $(date) ==="
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > /tmp/r17e-cand-rebuild.log 2>&1; echo "candidate_rebuild_exit=$?"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
rm -rf /tmp/r17e-base/.build
(cd /tmp/r17e-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
sha256sum /tmp/r17e-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
git worktree remove --force /tmp/r17e-base
echo "DONE $(date)"
