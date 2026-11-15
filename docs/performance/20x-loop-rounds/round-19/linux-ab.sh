#!/bin/bash
# Round 19 Linux screening A/B (v1 at fe17ef1; generated from the round-16
# fixed-harness template — review F6: the stale round-16 header is corrected
# here, the operative candidate of this archived run is fe17ef1): the checks
# binary embeds
# #filePath, so build trees must stay alive while checks run, and the rebuild
# verification must happen at the SAME path. Candidate builds in the main
# worktree (HEAD=fe17ef1, porcelain 0 = committed tree); baseline in a scratch
# worktree kept alive through its check run.
set -u
export PATH=$HOME/.local/swift/6.3.3/usr/bin:$PATH
FINAL=fe17ef1
MAIN=<worktree>
cd "$MAIN"
out=.local/round19
mkdir -p "$out/ab19"
echo "HEAD_main=$(git rev-parse HEAD)"
echo "porcelain_main=$(git status --porcelain | wc -l | tr -d ' ')"
echo "=== build candidate in main worktree ($FINAL) $(date) ==="
swift build -c release --product WorkbenchChecks > /tmp/r19-cand-build.log 2>&1; echo "candidate_build_exit=$?"
cp .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/cand-checks19"
echo "=== build baseline (89e5976 + $FINAL tests; tree kept alive) $(date) ==="
rm -rf /tmp/r19-base
git worktree add --detach /tmp/r19-base 89e5976 >/dev/null 2>&1
git -C /tmp/r19-base checkout "$FINAL" -- Tests/
(cd /tmp/r19-base && swift build -c release --product WorkbenchChecks > build.log 2>&1; echo "baseline_build_exit=$?")
cp /tmp/r19-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks "$out/base-checks19"
echo "=== checks both sides (trees alive) $(date) ==="
"$out/cand-checks19" > "$out/ab19/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab19/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab19/checks-cand.log")"
"$out/base-checks19" > "$out/ab19/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab19/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab19/checks-base.log")"
grep -E 'link detection' "$out/ab19/checks-base.log" "$out/ab19/checks-cand.log"
sha256sum "$out/base-checks19" "$out/cand-checks19" | tee "$out/ab19/binary-hashes.txt"
git show "$FINAL":Tests/WorkbenchCoreTests/PresentationBench.swift | sha256sum | sed 's|-|Tests/WorkbenchCoreTests/PresentationBench.swift|' > "$out/ab19/fixture-hashes.txt"
for f in StreamingBench ActivityBench EditLineBench BenchClock LinkScanMaterializeTests; do
  git show "$FINAL":Tests/WorkbenchCoreTests/$f.swift | sha256sum | sed "s|-|Tests/WorkbenchCoreTests/$f.swift|" >> "$out/ab19/fixture-hashes.txt"
done
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$out/base-checks19"
    [ "$variant" = candidate ] && bin="$out/cand-checks19"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab19/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base-checks19" "$out/cand-checks19" | tee "$out/ab19/binary-hashes-final.txt"
echo "=== rebuild verification (same paths, fresh .build) $(date) ==="
rm -rf "$MAIN/.build/x86_64-unknown-linux-gnu"
swift build -c release --product WorkbenchChecks > /tmp/r19-cand-rebuild.log 2>&1; echo "candidate_rebuild_exit=$?"
sha256sum .build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
rm -rf /tmp/r19-base/.build
(cd /tmp/r19-base && swift build -c release --product WorkbenchChecks > rebuild.log 2>&1; echo "baseline_rebuild_exit=$?")
sha256sum /tmp/r19-base/.build/x86_64-unknown-linux-gnu/release/WorkbenchChecks
git worktree remove --force /tmp/r19-base
echo "DONE $(date)"
