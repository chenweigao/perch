#!/bin/bash
set -euo pipefail
printf 'observed_at=%s\n' "$(date -Iseconds)"
pgrep -fl 'PerfRunner|perfrunner' || true
queued_jobs=0
for pending_job in "$HOME/Library/PerfRunner/jobs"/*.job; do
    if test -f "$pending_job"; then
        printf 'queued_job=%s\n' "$(basename "$pending_job")"
        queued_jobs=$((queued_jobs + 1))
    fi
done
printf 'queued_jobs=%s\n' "$queued_jobs"
test "$queued_jobs" = 0
cd "$HOME/_worktrees/20x-loop-20261112/perch"
printf 'shared_head=%s\n' "$(git rev-parse HEAD)"
shared_porcelain=$(git status --porcelain=v1 | wc -l | tr -d ' ')
printf 'shared_porcelain=%s\n' "$shared_porcelain"
test "$shared_porcelain" = 0
test -f "$HOME/Library/PerfRunner/results/style-r7-before-v1.done"
test "$(tail -1 "$HOME/Library/PerfRunner/results/style-r7-before-v1.log")" = 'exit=0'
for job_suffix in '' .done .log; do
    test ! -e "$HOME/Library/PerfRunner/results/style-r7-after-v1$job_suffix"
    test ! -e "$HOME/Library/PerfRunner/results/style-r7-gates-v1$job_suffix"
done
test ! -e "$HOME/Library/PerfRunner/jobs/style-r7-after-v1.job"
test ! -e "$HOME/Library/PerfRunner/jobs/style-r7-gates-v1.job"
support="$HOME/Library/PerfRunner/results/style-r7-support-v1"
shasum -a 256 "$support/before-support.sha256" "$support/frozen-masks.json" "$support/perfrunner-after.job" "$support/perfrunner-gates.job"
(cd "$support" && shasum -a 256 -c before-support.sha256)
printf 'after_preflight=passed\n'
