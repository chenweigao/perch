#!/bin/bash
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
scp -q -o BatchMode=yes .local/round18/r18-product.patch "mac-mini:$MLOGS/r18-product.patch" || exit 1
scp -q -o BatchMode=yes .local/round18/mac-ab-r18.sh "mac-mini:$MLOGS/round18-ab.sh" || exit 1
ssh -o BatchMode=yes mac-mini "rm -f $MLOGS/ab18-driver.log; nohup bash $MLOGS/round18-ab.sh > $MLOGS/ab18-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab18-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s"; break
  fi
  sleep 20
done
mkdir -p .local/round18/macos-ab
scp -o BatchMode=yes "mac-mini:$MLOGS/ab18/*" .local/round18/macos-ab/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab18-driver.log" .local/round18/macos-ab-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=' $MLOGS/ab18-driver.log | grep -v 'pair=' | head -20" || true
echo "WAIT_DONE $(date)"
