#!/bin/bash
# Run after the release build. Measures the same projection used by ConversationTranscript.
set -euo pipefail
cd "$(dirname "$0")/.."
bin_dir="$PWD/.build/release"
mkdir -p .local
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    while IFS= read -r file; do objects+=("$file"); done < <(rg --files --hidden --no-ignore "$bin_dir/$target.build" | rg '\.o$')
done
swiftc -O -swift-version 5 -parse-as-library -I "$bin_dir/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include \
    Tests/Performance/TranscriptBenchmark.swift "${objects[@]}" -o .local/transcript-benchmark
.local/transcript-benchmark
