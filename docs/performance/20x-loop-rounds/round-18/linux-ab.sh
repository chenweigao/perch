#!/bin/bash
# Round 18 Linux A/B (documents the platform-specific gain we do NOT count):
# base = .local/round18/base (a13aee2 product), cand = .local/round18/cand
# (+ visible() whitespace patch). Both already built during screening.
set -u
cd <worktree>
out=.local/round18
mkdir -p "$out/ab"
echo "=== hashes ==="
sha256sum "$out/base" "$out/cand" | tee "$out/ab/binary-hashes.txt"
echo "=== checks both sides ==="
"$out/base" > "$out/ab/checks-base.log" 2>&1; echo "baseline_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab/checks-base.log") skip=$(grep -c '^SKIP' "$out/ab/checks-base.log")"
"$out/cand" > "$out/ab/checks-cand.log" 2>&1; echo "candidate_checks_exit=$? pass=$(grep -c '^PASS' "$out/ab/checks-cand.log") skip=$(grep -c '^SKIP' "$out/ab/checks-cand.log")"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in base cand; do
    bin="$out/$variant"
    for mode in 1 streaming activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$out/ab/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
done
sha256sum "$out/base" "$out/cand" | tee "$out/ab/binary-hashes-final.txt"
echo "DONE $(date)"
