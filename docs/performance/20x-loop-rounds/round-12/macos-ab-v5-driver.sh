#!/bin/bash
# Ship the rendered-identity-fixed patches (7d5ba26..13933f8), run the Mac A/B
# v3, fetch results, then re-run the prefix(320) screening microbench from its
# retained SwiftPM scratch package to archive a verifiable run log (review Q7).
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261114
git diff 7d5ba26 13933f8 -- Tests/ > .local/round12/tests-v3.patch
git diff 7d5ba26 13933f8 -- Sources/ > .local/round12/product-v3.patch
wc -l .local/round12/tests-v3.patch .local/round12/product-v3.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab12e-driver.log; rm -rf $MLOGS/ab12e" || exit 1
scp -o BatchMode=yes .local/round12/tests-v3.patch "mac-mini:$MLOGS/round12-tests-v5.patch" || exit 1
scp -o BatchMode=yes .local/round12/product-v3.patch "mac-mini:$MLOGS/round12-product-v5.patch" || exit 1
scp -o BatchMode=yes .local/round12/mac-ab-v5.sh "mac-mini:$MLOGS/round12-ab-v5.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round12-ab-v5.sh > $MLOGS/ab12e-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab12e-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"
    break
  fi
  sleep 20
done
mkdir -p .local/round12/macos-ab-v5
scp -o BatchMode=yes "mac-mini:$MLOGS/ab12e/*" .local/round12/macos-ab-v5/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab12e-driver.log" .local/round12/macos-ab-v5-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=|SearchEntryReuse' $MLOGS/ab12e-driver.log | grep -v 'pair=' | head -25" || true
echo "WAIT_DONE $(date)"
