#!/bin/bash
set -euo pipefail
support="$HOME/Library/PerfRunner/results/style-r7-support-v1"
candidate_revision=5970638a64a73e352867ad8e5ffeca9341f9d66b
expected_job_sha256=0dfa1d6c7f5d1620c3487540040726c53c5f9d44a14815ea71c823b8e1c84c78
runner_pids=$(pgrep -f "$HOME/Library/PerfRunner/runner.sh")
test -n "$runner_pids"
printf 'runner_pids=%s\n' "$runner_pids"
for pending_job in "$HOME/Library/PerfRunner/jobs"/*.job; do
    test ! -f "$pending_job"
done
cd "$HOME/_worktrees/20x-loop-20261112/perch"
test -z "$(git status --porcelain=v1)"
remote_candidate=$(git ls-remote origin refs/heads/style/loop-main | awk '{print $1}')
test "$remote_candidate" = "$candidate_revision"
for job_suffix in '' .done .log; do
    test ! -e "$HOME/Library/PerfRunner/results/style-r7-after-v1$job_suffix"
    test ! -e "$HOME/Library/PerfRunner/results/style-r7-gates-v1$job_suffix"
done
test ! -e "$HOME/Library/PerfRunner/jobs/style-r7-after-v1.job"
test ! -e "$HOME/Library/PerfRunner/jobs/.style-r7-after-v1.pending"
test -f "$HOME/Library/PerfRunner/results/style-r7-before-v1.done"
test "$(tail -1 "$HOME/Library/PerfRunner/results/style-r7-before-v1.log")" = 'exit=0'
test ! -e "$support/candidate-revision.txt"
test "$(cat "$support/candidate-revision.upload-v1.txt")" = "$candidate_revision"
test "$(shasum -a 256 "$support/perfrunner-after.job" | cut -d ' ' -f1)" = "$expected_job_sha256"
test "$(shasum -a 256 "$support/frozen-masks.json" | cut -d ' ' -f1)" = 7418ab2190596ee647a4f5f6db41e2fcda6aeb806b4dcc58ec4c55e001710104
(cd "$support" && shasum -a 256 -c before-support.sha256)
mv "$support/candidate-revision.upload-v1.txt" "$support/candidate-revision.txt"
cp "$support/perfrunner-after.job" "$HOME/Library/PerfRunner/jobs/.style-r7-after-v1.pending"
test "$(shasum -a 256 "$HOME/Library/PerfRunner/jobs/.style-r7-after-v1.pending" | cut -d ' ' -f1)" = "$expected_job_sha256"
mv "$HOME/Library/PerfRunner/jobs/.style-r7-after-v1.pending" "$HOME/Library/PerfRunner/jobs/style-r7-after-v1.job"
printf 'queued_at=%s\ncandidate_revision=%s\njob_sha256=%s\nstatus=queued_only\n' "$(date -Iseconds)" "$candidate_revision" "$expected_job_sha256"
