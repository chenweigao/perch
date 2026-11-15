#!/bin/bash
set -u
cd <worktree>
FINAL=1f9b5d4
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
git diff 89e5976 "$FINAL" -- Tests/ > .local/round19/r19v2-tests.patch
git diff 89e5976 "$FINAL" -- Sources/ > .local/round19/r19v2-product.patch
wc -l .local/round19/r19v2-tests.patch .local/round19/r19v2-product.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab19v2-driver.log; rm -rf $MLOGS/ab19v2" || exit 1
scp -q -o BatchMode=yes .local/round19/r19v2-tests.patch "mac-mini:$MLOGS/r19v2-tests.patch" || exit 1
scp -q -o BatchMode=yes .local/round19/r19v2-product.patch "mac-mini:$MLOGS/r19v2-product.patch" || exit 1
scp -q -o BatchMode=yes .local/round19/mac-ab-r19v2.sh "mac-mini:$MLOGS/round19v2-ab.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round19v2-ab.sh > $MLOGS/ab19v2-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 270); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab19v2-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"; break
  fi
  sleep 20
done
mkdir -p .local/round19/macos-ab-v2
scp -o BatchMode=yes "mac-mini:$MLOGS/ab19v2/*" .local/round19/macos-ab-v2/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab19v2-driver.log" .local/round19/macos-ab-v2-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=|ABORT|splitInline' $MLOGS/ab19v2-driver.log | grep -v 'pair=' | head -24" || true
echo "WAIT_DONE $(date)"
