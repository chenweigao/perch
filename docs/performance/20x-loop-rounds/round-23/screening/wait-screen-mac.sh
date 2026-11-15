#!/bin/bash
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
for i in $(seq 1 270); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/screen23-driver.log" 2>/dev/null; then
    echo "mac screening done after ~$((i*20))s"; break
  fi
  sleep 20
done
mkdir -p .local/round23/screen-mac
scp -o BatchMode=yes "mac-mini:$MLOGS/screen23/*" .local/round23/screen-mac/ 2>/dev/null || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/screen23-driver.log" .local/round23/screen-mac-driver.log || echo "log_warn=$?"
grep -E "exit=|pass=|HEAD=|patch=|porcelain|shasum|edit512|edit64|edit_stats|stream_narrative|byte-range" .local/round23/screen-mac-driver.log | grep -v "^===" | head -60
echo "WAIT_DONE $(date)"
