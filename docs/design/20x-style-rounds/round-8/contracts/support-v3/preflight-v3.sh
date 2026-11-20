#!/bin/bash
set -euo pipefail
export GIT_OPTIONAL_LOCKS=0
printf 'observed_at=%s\n' "$(date -Iseconds)"
pgrep -f "$HOME/Library/PerfRunner/runner.sh"
pending=0
for job in "$HOME/Library/PerfRunner/jobs"/*.job; do
    if test -f "$job"; then printf 'nonterminal_job=%s\n' "$(basename "$job")"; pending=$((pending + 1)); fi
done
printf 'nonterminal_jobs=%s\n' "$pending"
test "$pending" = 0
processes=$(ps -axo pid=,comm= | awk '$2 ~ /^(swift|swift-build|swift-frontend|HostLifecycleChecks|AgentWorkbench|WorkbenchPreview|SidebarPreview|ComposerPreview)$/ {print}')
printf 'build_or_fixture_processes=%s\n' "$processes"
test -z "$processes"
cd "$HOME/_worktrees/20x-loop-20261112/perch"
test -z "$(git status --porcelain=v1)"
test "$(git rev-parse HEAD)" = 91711d43897f6e3d2726ea45e3bcad0f3fb71f44
git ls-remote origin refs/heads/main refs/heads/style/loop-main
app="$HOME/Library/PerfRunner/results/style-functional-contract-gates-20261120-v2/HostLifecycleChecks.app"
test "$(shasum -a 256 "$app/Contents/MacOS/HostLifecycleChecks" | cut -d ' ' -f1)" = 78554ceb1feb6764e9630938ac696a2051e798c8951b83c7c29f450fc1554f05
test "$(shasum -a 256 "$app/Contents/Info.plist" | cut -d ' ' -f1)" = 46f71da6131742ec9fbeb35ecef675c8049e4c5aed2449aafe48bdca76e4396f
test -x "$HOME/.local/opt/node-v24.18.0-darwin-arm64/bin/node"
printf "preflight=PASS_NO_GUI_OR_BUILD\n"
