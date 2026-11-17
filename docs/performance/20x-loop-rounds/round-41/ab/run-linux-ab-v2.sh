#!/bin/bash
# Round-41 Linux formal A/B v2 batch (six alternating pairs, release,
# five modes). base=/tmp/r41-v1-rel (dade949f), cand=/tmp/r41-v6-rel
# (f69883a3 = v5 + review F1-F4 fixes). Supersedes ab41v1-linux (v5
# bytes). Primary: commentary_chain_total (streaming). Guards:
# chain_total + all streaming stages + the other four modes.
set -u
cd /home/<dev>/.t3/worktrees/perch/t3-b3eb4bba-c5db753ed6879e15
RES=.local/round41/ab41v2-linux
rm -rf "$RES"; mkdir -p "$RES"
BASE=/tmp/r41-v1-rel
CAND=/tmp/r41-v6-rel
echo "=== prepare $(date) ==="
md5sum "$BASE" "$CAND" | tee "$RES/binary-hashes.txt"
echo "=== checks both sides $(date) ==="
"$BASE" > "$RES/checks-base.log" 2>&1; echo "base_checks_exit=$?"
"$CAND" > "$RES/checks-cand.log" 2>&1; echo "cand_checks_exit=$?"
grep -c '^PASS' "$RES/checks-base.log" "$RES/checks-cand.log"
grep -h 'commentary derivator' "$RES/checks-cand.log"
echo "=== pairs $(date) ==="
for pair in 1 2 3 4 5 6; do
  for variant in baseline candidate; do
    bin="$BASE"
    [ "$variant" = candidate ] && bin="$CAND"
    for mode in streaming 1 activity edit-lines presentation-token; do
      WORKBENCH_BENCH="$mode" "$bin" > "$RES/pair$pair-$variant-$mode.log" 2>&1
      echo "pair=$pair variant=$variant mode=$mode exit=$?"
    done
  done
  echo "pair$pair done $(date)"
done
md5sum "$BASE" "$CAND" | tee "$RES/binary-hashes-final.txt"
echo "DONE $(date)"
