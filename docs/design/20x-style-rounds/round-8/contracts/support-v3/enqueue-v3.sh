#!/bin/bash
set -euo pipefail
support="$HOME/Library/PerfRunner/results/style-r8-support-20261120-v3"
job="$HOME/Library/PerfRunner/jobs/style-r8-capture-gates-20261120-v3.job"
output="$HOME/Library/PerfRunner/results/style-r8-capture-gates-20261120-v3"
test ! -e "$job"
for suffix in '' .log .done .raw.tar.gz .archive-manifest.json; do test ! -e "$output$suffix"; done
pgrep -f "$HOME/Library/PerfRunner/runner.sh"
pending=0
for existing in "$HOME/Library/PerfRunner/jobs"/*.job; do
    if test -f "$existing"; then printf 'nonterminal_job=%s\n' "$(basename "$existing")"; pending=$((pending + 1)); fi
done
test "$pending" = 0
(cd "$support" && shasum -a 256 -c SHA256SUMS)
test ! -e "$job.pending"
cp "$support/perfrunner-r8-v3.job" "$job.pending"
mv "$job.pending" "$job"
printf 'enqueued_at=%s\njob=style-r8-capture-gates-20261120-v3\n' "$(date -Iseconds)"
