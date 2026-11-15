#!/bin/bash
set -u
cd <worktree>
FINAL=e2ff3c0
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
git diff ed53341 "$FINAL" -- Tests/ > .local/round22/r22-tests-formal.patch
git diff ed53341 "$FINAL" -- Sources/ > .local/round22/r22-product-formal.patch
wc -l .local/round22/r22-tests-formal.patch .local/round22/r22-product-formal.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab22-driver.log; rm -rf $MLOGS/ab22" || exit 1
scp -q -o BatchMode=yes .local/round22/r22-tests-formal.patch "mac-mini:$MLOGS/r22-tests.patch" || exit 1
scp -q -o BatchMode=yes .local/round22/r22-product-formal.patch "mac-mini:$MLOGS/r22-product.patch" || exit 1
scp -q -o BatchMode=yes .local/round22/mac-ab-r22.sh "mac-mini:$MLOGS/round22-ab.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round22-ab.sh > $MLOGS/ab22-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 270); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab22-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"; break
  fi
  sleep 20
done
mkdir -p .local/round22/macos-ab
scp -o BatchMode=yes "mac-mini:$MLOGS/ab22/*" .local/round22/macos-ab/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab22-driver.log" .local/round22/macos-ab-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=|ABORT|phase single-pass' $MLOGS/ab22-driver.log | grep -v 'pair=' | head -24" || true
echo "WAIT_DONE $(date)"
