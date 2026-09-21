#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
remote_host="dev-env"
with_dsh=0
for arg in "$@"; do
  case "$arg" in
    --with-dsh) with_dsh=1 ;;
    -h|--help) echo "usage: $0 [host] [--with-dsh]"; exit 0 ;;
    *) remote_host="$arg" ;;
  esac
done
# This installs only the Workbench broker and SDK; it does not replace the user's CLI.
ssh -o BatchMode=yes "$remote_host" 'mkdir -p ~/.local/share/agent-workbench/native; chmod 700 ~/.local/share/agent-workbench/native'
scp -q remote/native-agent-service.py remote/qoder-worker.mjs remote/package.json "$remote_host:.local/share/agent-workbench/native/"
ssh -o BatchMode=yes "$remote_host" 'cd ~/.local/share/agent-workbench/native && npm install --ignore-scripts'
if [ "$with_dsh" = "1" ]; then
  # The pinned SDK wheel carries the full dsh runtime (no Node needed on the host);
  # the marker file tells the broker which binary to launch.
  ssh -o BatchMode=yes "$remote_host" 'set -e; cd ~/.local/share/agent-workbench/native &&
    python3 -m venv dsh-venv &&
    ./dsh-venv/bin/pip install --quiet "deepseek-harness-sdk==0.1.5rc1" &&
    ./dsh-venv/bin/python -c "from deepseek_harness_runtime import bundled_runtime_path; print(bundled_runtime_path())" > dsh-runtime &&
    chmod 600 dsh-runtime'
fi
# The Mac app starts/reuses the broker through --ensure. Never kill an active broker during install.
