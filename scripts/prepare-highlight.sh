#!/bin/bash
# Pinned upstream resource. The optional argument is an app's Resources directory.
set -euo pipefail
cd "$(dirname "$0")/.."
source_js="Resources/Highlight/highlight.min.js"
expected="c4a399dd6f488bc97a3546e3476747b3e714c99c57b9473154c6fb8d259b9381"
if [ ! -f "$source_js" ]; then
    curl --fail --location --max-time 60 \
        https://raw.githubusercontent.com/highlightjs/cdn-release/11.11.1/build/highlight.min.js \
        -o "$source_js.tmp"
    mv "$source_js.tmp" "$source_js"
fi
if [ "$(shasum -a 256 "$source_js" | cut -d ' ' -f 1)" != "$expected" ]; then
    echo "highlight.js digest mismatch: $source_js" >&2
    exit 1
fi
if [ "$#" -gt 0 ]; then
    mkdir -p "$1"
    cp "$source_js" "$1/highlight.min.js"
fi
