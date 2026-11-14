#!/bin/bash
# Round 16 Linux A/B (rerun with fixed harness): the checks binary embeds
# #filePath, so build trees must stay alive while checks run, and the rebuild
# verification must happen at the SAME path. Candidate builds in the main
# worktree (HEAD=9e7bc19, porcelain 0 = committed tree); baseline in a scratch
# worktree kept alive through its check run.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=413bf86
MAIN=<worktree>
cd "$MAIN"
out=.local/round16
mkdir -p "$out/ab4"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r16d-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks4"
echo "=== build baseline (15f612f + $FINAL tests; tree kept alive) $(date) ==="
rm -rf /tmp/r16d-base
git worktree add --detach /tmp/r16d-base 15f612f >/dev/null 2>&1
git -C /tmp/r16d-base checkout "$FINAL" -- Tests/
(cd /tmp/r16d-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r16d-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks4"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks4" > "$out/ab4/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab4/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab4/checks-cand.log")"
"$out/base-checks4" > "$out/ab4/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab4/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab4/checks-base.log")"
grep -E 'link detection' "$out/ab4/checks-base.log" "$out/ab4/checks-cand.log"
sha256sum "$out/base-checks4" "$out/cand-checks4" | tee "$out/ab4/binary-hashes.txt"
git show "$FINAL":Tests/WorkbenchCoreTests/PresentationBench.swift | sha256sum | sed 's|-|Tests/WorkbenchCoreTests/PresentationBench.swift|' > "$out/ab4/fixture-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock LinkScanMaterializeTests; do
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift | sha256sum | sed "s|-|Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab4/fixture-hashes.txt"
done
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks4"
    [ "$variant" = candidate ] && bin="$out/cand-checks4"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab4/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks4" "$out/cand-checks4" | tee "$out/ab4/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) $(date) ==="
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > /tmp/r16d-cand-rebuild.log 2>&1; echo "candidate_rebuild_exit=$?"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
rm -rf /tmp/r16d-base/.build
(cd /tmp/r16d-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
sha256sum /tmp/r16d-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
git worktree remove --force /tmp/r16d-base
echo "DONE $(date)"
