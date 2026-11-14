#!/bin/bash
# Ship the rendered-identity-fixed patches (7d5ba26..b87488c), run the Mac A/B
# v3, fetch results, then re-run the prefix(320) screening microbench from its
# retained SwiftPM scratch package to archive a verifiable run log (review Q7).
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261114
git diff 7d5ba26 b87488c -- Tests/ > .local/round12/tests-v3.patch
git diff 7d5ba26 b87488c -- Sources/ > .local/round12/product-v3.patch
wc -l .local/round12/tests-v3.patch .local/round12/product-v3.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab12d-driver.log; rm -rf $MLOGS/ab12d" || exit 1
scp -o BatchMode=yes .local/round12/tests-v3.patch "mac-mini:$MLOGS/round12-tests-v4.patch" || exit 1
scp -o BatchMode=yes .local/round12/product-v3.patch "mac-mini:$MLOGS/round12-product-v4.patch" || exit 1
scp -o BatchMode=yes .local/round12/mac-ab-v4.sh "mac-mini:$MLOGS/round12-ab-v4.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round12-ab-v4.sh > $MLOGS/ab12d-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab12d-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"
    break
  fi
  sleep 20
done
mkdir -p .local/round12/macos-ab-v4
scp -o BatchMode=yes "mac-mini:$MLOGS/ab12d/*" .local/round12/macos-ab-v4/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab12d-driver.log" .local/round12/macos-ab-v4-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=|SearchEntryReuse' $MLOGS/ab12d-driver.log | grep -v 'pair=' | head -25" || true
echo "WAIT_DONE $(date)"
