#!/bin/bash
# Waiter for the Mac round-27 formal A/B job. Polls for DONE, fetches results.
set -u
MLOGS="/Users/<mini>/Library/Logs/perf-loop-20261116"
LOCAL=".local/round27/macos-ab"
for i in $(seq 1 300); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' '$MLOGS/ab27-driver.log' 2>/dev/null"; then
    echo "=== driver log ==="
    ssh -o BatchMode=yes mac-mini "cat '$MLOGS/ab27-driver.log'"
    rm -rf "$LOCAL"; mkdir -p "$LOCAL"
    scp -q -r -o BatchMode=yes "mac-mini:$MLOGS/ab27/*" "$LOCAL/" && echo "fetched to $LOCAL"
    ls "$LOCAL" | head -20; ls "$LOCAL" | wc -l
    exit 0
  fi
  sleep 60
done
echo "TIMEOUT waiting for Mac A/B"
exit 1
