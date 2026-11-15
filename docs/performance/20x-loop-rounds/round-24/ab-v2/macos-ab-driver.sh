#!/bin/bash
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
for i in $(seq 1 270); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab24v2-driver.log" 2>/dev/null; then
    echo "mac r24v2 done after ~$((i*20))s of waiting"; break
  fi
  sleep 20
done
mkdir -p .local/round24/macos-ab-v2
scp -o BatchMode=yes "mac-mini:$MLOGS/ab24/*" .local/round24/macos-ab-v2/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab24v2-driver.log" .local/round24/macos-ab-v2-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=|ABORT|MISMATCH|walk' $MLOGS/ab24v2-driver.log | grep -v 'pair=' | head -24" || true
echo "WAIT_DONE $(date)"
