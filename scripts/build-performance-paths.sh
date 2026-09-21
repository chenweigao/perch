#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="${1:-$PWD}"
variant="${2:-candidate}"
bin_dir="$root/.build/release"
mkdir -p .local/performance-paths
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    while IFS= read -r file; do objects+=("$file"); done < <(rg --files --hidden --no-ignore "$bin_dir/$target.build" | rg '\.o$' | sort)
done
flags=()
if [[ "$variant" == candidate ]]; then flags=(-D PERFORMANCE_PATHS); fi
swiftc -O -swift-version 5 "${flags[@]}" -I "$bin_dir/Modules" \
    -I "$root/.build/checkouts/swift-markdown/Sources/CAtomic/include" \
    -I "$root/.build/checkouts/swift-cmark/src/include" \
    -I "$root/.build/checkouts/swift-cmark/extensions/include" \
    Tests/PerformancePaths/main.swift "${objects[@]}" -o ".local/performance-paths/$variant"
