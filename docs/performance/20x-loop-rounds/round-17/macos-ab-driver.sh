#!/bin/bash
set -u
cd <worktree>
FINAL=66a94d5
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
git diff 76940c0 "$FINAL" -- Tests/ > .local/round17/r17-tests-final2.patch
git diff 76940c0 "$FINAL" -- Sources/ > .local/round17/r17-product-final2.patch
wc -l .local/round17/r17-tests-final2.patch .local/round17/r17-product-final2.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab17e-driver.log; rm -rf $MLOGS/ab17e" || exit 1
scp -q -o BatchMode=yes .local/round17/r17-tests-final2.patch "mac-mini:$MLOGS/r17-tests-final2.patch" || exit 1
scp -q -o BatchMode=yes .local/round17/r17-product-final2.patch "mac-mini:$MLOGS/r17-product-final2.patch" || exit 1
scp -q -o BatchMode=yes .local/round17/mac-ab-r17c.sh "mac-mini:$MLOGS/round17-ab.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round17-ab.sh > $MLOGS/ab17e-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab17e-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"; break
  fi
  sleep 20
done
mkdir -p .local/round17/macos-ab-v3
scp -o BatchMode=yes "mac-mini:$MLOGS/ab17e/*" .local/round17/macos-ab-v3/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab17e-driver.log" .local/round17/macos-ab-v3-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=|ABORT|normalizeDelimiters' $MLOGS/ab17e-driver.log | grep -v 'pair=' | head -22" || true
echo "WAIT_DONE $(date)"
