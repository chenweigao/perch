#!/bin/bash
set -u
cd <worktree>
FINAL=413bf86
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261115
git diff 15f612f "$FINAL" -- Tests/ > .local/round16/r16-tests-final-d.patch
git diff 15f612f "$FINAL" -- Sources/ > .local/round16/r16-product-final-d.patch
wc -l .local/round16/r16-tests-final-d.patch .local/round16/r16-product-final-d.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab16d-driver.log; rm -rf $MLOGS/ab16d" || exit 1
scp -q -o BatchMode=yes .local/round16/r16-tests-final-d.patch "mac-mini:$MLOGS/r16-tests-final-d.patch" || exit 1
scp -q -o BatchMode=yes .local/round16/r16-product-final-d.patch "mac-mini:$MLOGS/r16-product-final-d.patch" || exit 1
scp -q -o BatchMode=yes .local/round16/mac-ab-r16d.sh "mac-mini:$MLOGS/round16-ab-d.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round16-ab-d.sh > $MLOGS/ab16d-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab16d-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"; break
  fi
  sleep 20
done
mkdir -p .local/round16/macos-ab-d
scp -o BatchMode=yes "mac-mini:$MLOGS/ab16d/*" .local/round16/macos-ab-d/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab16d-driver.log" .local/round16/macos-ab-d-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=|link detection|ABORT' $MLOGS/ab16d-driver.log | grep -v 'pair=' | head -22" || true
echo "WAIT_DONE $(date)"
