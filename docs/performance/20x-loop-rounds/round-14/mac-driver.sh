#!/bin/bash
# Ship round-14 patches (6c8241c..HEAD), run the Mac A/B, fetch results.
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261114
git diff 6c8241c HEAD -- Tests/ > .local/round14/tests.patch
git diff 6c8241c HEAD -- Sources/ > .local/round14/product.patch
wc -l .local/round14/tests.patch .local/round14/product.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab14-driver.log; rm -rf $MLOGS/ab14" || exit 1
scp -o BatchMode=yes .local/round14/tests.patch "mac-mini:$MLOGS/round14-tests.patch" || exit 1
scp -o BatchMode=yes .local/round14/product.patch "mac-mini:$MLOGS/round14-product.patch" || exit 1
scp -o BatchMode=yes .local/round14/mac-ab.sh "mac-mini:$MLOGS/round14-ab.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round14-ab.sh > $MLOGS/ab14-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab14-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"
    break
  fi
  sleep 20
done
mkdir -p .local/round14/macos-ab
scp -o BatchMode=yes "mac-mini:$MLOGS/ab14/*" .local/round14/macos-ab/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab14-driver.log" .local/round14/macos-ab-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=' $MLOGS/ab14-driver.log | grep -v 'pair=' | head -20" || true
echo "WAIT_DONE $(date)"
