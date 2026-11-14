#!/bin/bash
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
git diff 9c12eb9 HEAD -- Tests/ > .local/round15/tests.patch
git diff 9c12eb9 HEAD -- Sources/ > .local/round15/product.patch
wc -l .local/round15/tests.patch .local/round15/product.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab15-driver.log; rm -rf $MLOGS/ab15" || exit 1
scp -o BatchMode=yes .local/round15/tests.patch "mac-mini:$MLOGS/round15-tests.patch" || exit 1
scp -o BatchMode=yes .local/round15/product.patch "mac-mini:$MLOGS/round15-product.patch" || exit 1
scp -o BatchMode=yes .local/round15/mac-ab.sh "mac-mini:$MLOGS/round15-ab.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round15-ab.sh > $MLOGS/ab15-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab15-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"; break
  fi
  sleep 20
done
mkdir -p .local/round15/macos-ab
scp -o BatchMode=yes "mac-mini:$MLOGS/ab15/*" .local/round15/macos-ab/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab15-driver.log" .local/round15/macos-ab-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=' $MLOGS/ab15-driver.log | grep -v 'pair=' | head -20" || true
echo "WAIT_DONE $(date)"
