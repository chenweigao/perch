#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
remote_host="${1:-dev-env}"
# This installs only the Workbench broker and SDK; it does not replace the user's CLI.
ssh -o BatchMode=yes "$remote_host" 'mkdir -p ~/.local/share/agent-workbench/native; chmod 700 ~/.local/share/agent-workbench/native'
scp -q remote/native-agent-service.py remote/qoder-worker.mjs remote/package.json "$remote_host:.local/share/agent-workbench/native/"
ssh -o BatchMode=yes "$remote_host" 'cd ~/.local/share/agent-workbench/native && npm install --ignore-scripts'
# The Mac app starts/reuses the broker through --ensure. Never kill an active broker during install.
