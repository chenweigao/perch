#!/bin/bash
set -euo pipefail
output="$HOME/Library/PerfRunner/results/style-r7-after-v1"
support="$HOME/Library/PerfRunner/results/style-r7-support-v1"
metadata="$HOME/Library/PerfRunner/results/style-r7-after-v1-metadata"
archive="$HOME/Library/PerfRunner/results/style-r7-after-v1.original.tar.gz"
test -f "$output.done"
test "$(tail -1 "$output.log")" = 'exit=0'
test "$(cat "$output/candidate-revision.txt")" = 5970638a64a73e352867ad8e5ffeca9341f9d66b
test ! -e "$metadata"
test ! -e "$archive"
mkdir "$metadata"
cp "$output.done" "$metadata/mac-after.done"
cp "$output.log" "$metadata/mac-after.log"
cp "$support/capture-matrix.py" "$metadata/capture-matrix.py"
cp "$support/perfrunner-after.job" "$metadata/perfrunner-after.job"
cp "$support/before-support.sha256" "$metadata/before-support.sha256"
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$output" capture candidate-revision.txt expected-differences-before.md color-geometry-before.json frozen-masks.json -C "$metadata" mac-after.done mac-after.log capture-matrix.py perfrunner-after.job before-support.sha256
printf 'packaged_at=%s\n' "$(date -Iseconds)"
shasum -a 256 "$archive"
