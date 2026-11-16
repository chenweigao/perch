#!/bin/bash
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261116
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/screen26-driver.log" 2>/dev/null; then
    echo "mac screening done after ~$((i*20))s"; break
  fi
  sleep 20
done
mkdir -p .local/round26/screen-mac
scp -o BatchMode=yes "mac-mini:$MLOGS/screen26/*" .local/round26/screen-mac/ 2>/dev/null || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/screen26-driver.log" .local/round26/screen-mac-driver.log || echo "log_warn=$?"
grep -E "exit=|pass=|HEAD=|patch=|porcelain|shasum|delimiter scan|ABORT|longtail|token200|stream_narrative" .local/round26/screen-mac-driver.log | grep -v "^===" | head -40
echo "WAIT_DONE $(date)"
