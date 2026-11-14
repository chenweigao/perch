#!/bin/bash
# Ship the rendered-identity-fixed patches (7d5ba26..23bebb2), run the Mac A/B
# v3, fetch results, then re-run the prefix(320) screening microbench from its
# retained SwiftPM scratch package to archive a verifiable run log (review Q7).
set -u
cd <worktree>
MLOGS=/Users/<mini>/Library/Logs/perf-loop-20261114
git diff 7d5ba26 23bebb2 -- Tests/ > .local/round12/tests-v3.patch
git diff 7d5ba26 23bebb2 -- Sources/ > .local/round12/product-v3.patch
wc -l .local/round12/tests-v3.patch .local/round12/product-v3.patch
ssh -o BatchMode=yes mac-mini "mkdir -p $MLOGS; rm -f $MLOGS/ab12c-driver.log; rm -rf $MLOGS/ab12c" || exit 1
scp -o BatchMode=yes .local/round12/tests-v3.patch "mac-mini:$MLOGS/round12-tests-v3.patch" || exit 1
scp -o BatchMode=yes .local/round12/product-v3.patch "mac-mini:$MLOGS/round12-product-v3.patch" || exit 1
scp -o BatchMode=yes .local/round12/mac-ab-v3.sh "mac-mini:$MLOGS/round12-ab-v3.sh" || exit 1
ssh -o BatchMode=yes mac-mini "nohup bash $MLOGS/round12-ab-v3.sh > $MLOGS/ab12c-driver.log 2>&1 & echo mac_pid=\$!" || exit 1
echo "started, waiting..."
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' $MLOGS/ab12c-driver.log" 2>/dev/null; then
    echo "mac done after ~$((i*20))s of waiting"
    break
  fi
  sleep 20
done
mkdir -p .local/round12/macos-ab-v3
scp -o BatchMode=yes "mac-mini:$MLOGS/ab12c/*" .local/round12/macos-ab-v3/ || echo "scp_warn=$?"
scp -o BatchMode=yes "mac-mini:$MLOGS/ab12c-driver.log" .local/round12/macos-ab-v3-driver.log || echo "log_warn=$?"
ssh -o BatchMode=yes mac-mini "grep -E 'exit=|pass=|HEAD=|porcelain|patch=|SearchEntryReuse' $MLOGS/ab12c-driver.log | grep -v 'pair=' | head -25" || true
echo "=== microbench rerun (review Q7 verifiable log) $(date) ==="
ssh -o BatchMode=yes mac-mini 'cd ~/Library/Logs/perf-loop-20261113/r12mb && swift build -c release 2>&1 | tail -1 && ./.build/release/r12mb 2>&1' > .local/round12/attr-evidence/microbench-rerun.log 2>&1
echo "microbench_rerun_exit=$?"
tail -12 .local/round12/attr-evidence/microbench-rerun.log
echo "WAIT_DONE $(date)"
