#!/bin/bash
set -euo pipefail
output="$HOME/Library/PerfRunner/results/style-r7-after-v1"
printf 'observed_at=%s\n' "$(date -Iseconds)"
if test -f "$output.done"; then
    printf 'state=terminal\n'
    tail -12 "$output.log"
elif test -f "$HOME/Library/PerfRunner/jobs/style-r7-after-v1.job"; then
    printf 'state=queued\n'
elif test -f "$output.log"; then
    printf 'state=running\n'
    tail -6 "$output.log"
else
    printf 'state=unknown\n'
fi
if test -d "$output/capture"; then
    original_png_files=$(find "$output/capture" -type f -name '*.png' | wc -l | tr -d ' ')
    printf 'current_original_png_files=%s\n' "$original_png_files"
fi
cd "$HOME/_worktrees/20x-loop-20261112/perch"
printf 'shared_head=%s\n' "$(git rev-parse HEAD)"
