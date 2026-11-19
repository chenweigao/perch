#!/bin/bash
set -euo pipefail
printf 'observed_at=%s\n' "$(date -Iseconds)"
runner_pids=$(pgrep -f "$HOME/Library/PerfRunner/runner.sh")
printf 'runner_pids=%s\n' "$runner_pids"
queued_jobs=0
for pending_job in "$HOME/Library/PerfRunner/jobs"/*.job; do
    if test -f "$pending_job"; then
        printf 'queued_job=%s\n' "$(basename "$pending_job")"
        queued_jobs=$((queued_jobs + 1))
    fi
done
printf 'queued_jobs=%s\n' "$queued_jobs"
test -f "$HOME/Library/PerfRunner/results/style-r7-before-v1.done"
test -f "$HOME/Library/PerfRunner/results/style-r7-after-v1.done"
for stage in before after; do
    printf '%s_last=%s\n' "$stage" "$(tail -1 "$HOME/Library/PerfRunner/results/style-r7-$stage-v1.log")"
done
for suffix in '' .done .log; do
    test ! -e "$HOME/Library/PerfRunner/results/style-r7-gates-v1$suffix"
done
test ! -e "$HOME/Library/PerfRunner/jobs/style-r7-gates-v1.job"
test ! -e "$HOME/Library/PerfRunner/jobs/style-r7-after-v1.job"
test ! -e "$HOME/Library/PerfRunner/results/style-r8-before-v1"
test ! -e "$HOME/Library/PerfRunner/jobs/style-r8-before-v1.job"
printf 'gates_and_next_round=not_queued\n'
cd "$HOME/_worktrees/20x-loop-20261112/perch"
printf 'shared_head=%s\n' "$(git rev-parse HEAD)"
printf 'shared_porcelain_lines=%s\n' "$(git status --porcelain=v1 | wc -l | tr -d ' ')"
