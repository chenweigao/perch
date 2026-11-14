#!/bin/bash
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
git diff 9c12eb9 HEAD -- Tests/ > .local/round15/tests-v2.patch
git diff 9c12eb9 HEAD -- Sources/ > .local/round15/product-v2.patch
wc -l .local/round15/tests-v2.patch .local/round15/product-v2.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab15b-driver.log; rm -rf $MLOGS/ab15b" || exit 1
scp -o BatchMode=yes .local/round15/tests-v2.patch "mac-mini:$MLOGS/round15-tests-v2.patch" || exit 1
scp -o BatchMode=yes .local/round15/product-v2.patch "mac-mini:$MLOGS/round15-product-v2.patch" || exit 1
scp -o BatchMode=yes .local/round15/mac-ab-v2.sh "mac-mini:$MLOGS/round15-ab-v2.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round15-ab-v2.sh > $MLOGS/ab15b-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab15b-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"; break
  fi
  sleep 20
done
mkdir -p .local/round15/macos-ab-v2
scp -o BatchMode=yes "mac-mini:$MLOGS/ab15b/*" .local/round15/macos-ab-v2/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab15b-driver.log" .local/round15/macos-ab-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=' $MLOGS/ab15b-driver.log | grep -v 'pair=' | head -20" || true
echo "WAIT_DONE $(date)"
