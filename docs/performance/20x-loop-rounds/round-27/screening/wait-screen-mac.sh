#!/bin/bash
# Waiter for the Mac round-27 screening job. Polls the remote driver log for
# DONE, then fetches the result dir and prints the driver log tail.
set -u
MLOGS="/Users/<mini>/Library/Logs/perf-loop-20261116"
LOCAL=".local/round27/mac-screen27"
for i in $(seq 1 240); do
  if ssh -o BatchMode=yes mac-mini "grep -q '^DONE' '$MLOGS/screen27-driver.log' 2>/dev/null"; then
    echo "=== driver log (tail) ==="
    ssh -o BatchMode=yes mac-mini "tail -40 '$MLOGS/screen27-driver.log'"
    rm -rf "$LOCAL"; mkdir -p "$LOCAL"
    scp -q -r -o BatchMode=yes "mac-mini:$MLOGS/screen27/*" "$LOCAL/" && echo "fetched to $LOCAL"
    ls -la "$LOCAL"
    exit 0
  fi
  sleep 60
done
echo "TIMEOUT waiting for Mac screening"
exit 1
