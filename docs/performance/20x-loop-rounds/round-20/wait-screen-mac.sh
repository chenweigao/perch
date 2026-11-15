#!/bin/bash
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
for i in $(seq 1 180); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/screen20-driver.log" 2>/dev/null; then
    echo "mac screening done after ~$((i*20))s"; break
  fi
  sleep 20
done
mkdir -p .local/round20/screen-mac
scp -o BatchMode=yes "mac-mini:$MLOGS/screen20/*" .local/round20/screen-mac/ 2>/dev/null || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/screen20-driver.log" .local/round20/screen-mac-driver.log || echo "log_warn=$?"
grep -E "exit=|pass=|HEAD=|patch=|porcelain|token|stage_narrative|shasum|[0-9a-f]{64}|narrative byte-keyed" .local/round20/screen-mac-driver.log | grep -v "^==" | head -40
echo "WAIT_DONE $(date)"
