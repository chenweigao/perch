#!/bin/bash
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261116
for i in $(seq 1 270); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab26-driver.log" 2>/dev/null; then
    echo "mac formal done after ~$((i*20))s"; break
  fi
  sleep 20
done
mkdir -p .local/round26/macos-ab
scp -o BatchMode=yes "mac-mini:$MLOGS/ab26/*" .local/round26/macos-ab/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab26-driver.log" .local/round26/macos-ab-driver.log || echo "log_warn=$?"
grep -E "exit=|pass=|HEAD=|porcelain|patch=|ABORT|delimiter scan" .local/round26/macos-ab-driver.log | grep -v "pair=" | head -20
echo "WAIT_DONE $(date)"
