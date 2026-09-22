#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
remote_host=""
provider="all"
with_dsh=0
for arg in "$@"; do
  case "$arg" in
    --with-dsh) with_dsh=1 ;;
    --provider=omp) provider="omp" ;;
    --provider=qoder) provider="qoder" ;;
    --provider=dsh) provider="dsh"; with_dsh=1 ;;
    -h|--help) echo "usage: $0 <host> [--provider=omp|qoder|dsh] [--with-dsh]"; exit 0 ;;
    *) remote_host="$arg" ;;
  esac
done
if [[ -z "$remote_host" || "$remote_host" == -* || "$remote_host" =~ [[:space:]] ]]; then
  echo 'Provide an SSH alias or user@host.' >&2
  exit 2
fi
# Bash defers TERM while a foreground SSH command runs. Wait on a background
# client so cancellation can terminate that local client and close its pipes.
client_pid=""
cancel_install() {
  trap - TERM INT
  if [[ -n "$client_pid" ]]; then
    kill "$client_pid" 2>/dev/null || true
    wait "$client_pid" 2>/dev/null || true
  fi
  exit 130
}
trap cancel_install TERM INT
run_client() {
  "$@" &
  client_pid=$!
  wait "$client_pid"
  client_pid=""
}
# This installs only the Workbench broker and SDK; it does not replace the user's CLI.
run_client ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$remote_host" 'mkdir -p ~/.local/share/agent-workbench/native; chmod 700 ~/.local/share/agent-workbench/native'
run_client scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 remote/native-agent-service.py remote/qoder-worker.mjs remote/package.json "$remote_host:.local/share/agent-workbench/native/"
if [[ "$provider" == "all" || "$provider" == "qoder" ]]; then
  run_client ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$remote_host" 'cd ~/.local/share/agent-workbench/native && npm install --ignore-scripts'
fi
if [ "$with_dsh" = "1" ]; then
  # The pinned SDK wheel carries the full dsh runtime (no Node needed on the host);
  # the marker file tells the broker which binary to launch.
  run_client ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$remote_host" 'set -e; cd ~/.local/share/agent-workbench/native &&
    python3 -m venv dsh-venv &&
    ./dsh-venv/bin/pip install --quiet "deepseek-harness-sdk==0.1.5rc1" &&
    ./dsh-venv/bin/python -c "from deepseek_harness_runtime import bundled_runtime_path; print(bundled_runtime_path())" > dsh-runtime &&
    chmod 600 dsh-runtime'
fi
# The Mac app starts/reuses the broker through --ensure. Never kill an active broker during install.
