#!/bin/bash
set -u
cd <worktree>
FINAL=9e7bc19
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
git diff 15f612f "$FINAL" -- Tests/ > .local/round16/r16-tests-final.patch
git diff 15f612f "$FINAL" -- Sources/ > .local/round16/r16-product-final.patch
wc -l .local/round16/r16-tests-final.patch .local/round16/r16-product-final.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab16-driver.log; rm -rf $MLOGS/ab16" || exit 1
scp -o BatchMode=yes .local/round16/r16-tests-final.patch "mac-mini:$MLOGS/r16-tests-final.patch" || exit 1
scp -o BatchMode=yes .local/round16/r16-product-final.patch "mac-mini:$MLOGS/r16-product-final.patch" || exit 1
scp -o BatchMode=yes .local/round16/mac-ab-r16.sh "mac-mini:$MLOGS/round16-ab.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round16-ab.sh > $MLOGS/ab16-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab16-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"; break
  fi
  sleep 20
done
mkdir -p .local/round16/macos-ab
scp -o BatchMode=yes "mac-mini:$MLOGS/ab16/*" .local/round16/macos-ab/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab16-driver.log" .local/round16/macos-ab-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=|link detection' $MLOGS/ab16-driver.log | grep -v 'pair=' | head -22" || true
echo "WAIT_DONE $(date)"
