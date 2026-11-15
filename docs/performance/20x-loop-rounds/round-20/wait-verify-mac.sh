#!/bin/bash
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
for i in $(seq 1 90); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/verify20-driver.log" 2>/dev/null; then
    echo "verify done after ~$((i*15))s"; break
  fi
  sleep 15
done
mkdir -p .local/round20/verify-mac
scp -o BatchMode=yes "mac-mini:$MLOGS/verify20/*" .local/round20/verify-mac/ 2>/dev/null || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/verify20-driver.log" .local/round20/verify-mac-driver.log || echo "log_warn=$?"
grep -E "exit=|pass=|HEAD=|porcelain|patch=|[0-9a-f]{64}|PASS: narrative|PASS: localization" .local/round20/verify-mac-driver.log | head -12
echo "WAIT_DONE $(date)"
