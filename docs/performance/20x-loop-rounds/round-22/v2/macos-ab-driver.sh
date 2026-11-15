#!/bin/bash
set -u
cd <worktree>
FINAL=e14c25d
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
git diff ed53341 "$FINAL" -- Tests/ > .local/round22/r22v2-tests-formal.patch
git diff ed53341 "$FINAL" -- Sources/ > .local/round22/r22v2-product-formal.patch
wc -l .local/round22/r22v2-tests-formal.patch .local/round22/r22v2-product-formal.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab22v2-driver.log; rm -rf $MLOGS/ab22v2" || exit 1
scp -q -o BatchMode=yes .local/round22/r22v2-tests-formal.patch "mac-mini:$MLOGS/r22v2-tests-formal.patch" || exit 1
scp -q -o BatchMode=yes .local/round22/r22v2-product-formal.patch "mac-mini:$MLOGS/r22v2-product-formal.patch" || exit 1
scp -q -o BatchMode=yes .local/round22/mac-ab-r22v2.sh "mac-mini:$MLOGS/round22v2-ab.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round22v2-ab.sh > $MLOGS/ab22v2-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 270); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab22v2-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"; break
  fi
  sleep 20
done
mkdir -p .local/round22/macos-ab-v2
scp -o BatchMode=yes "mac-mini:$MLOGS/ab22v2/*" .local/round22/macos-ab-v2/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab22v2-driver.log" .local/round22/macos-ab-v2-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=|ABORT|phase single-pass' $MLOGS/ab22v2-driver.log | grep -v 'pair=' | head -24" || true
echo "WAIT_DONE $(date)"
