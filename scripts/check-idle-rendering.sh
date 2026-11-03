#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$PWD/build/idle-rendering-checks"
mkdir -p "$check_dir"
# Compile the exact production shimmer alongside the indicator; only theme colors
# are stubbed. The source boundaries are checked so extraction cannot silently drift.
python3 - "$check_dir/Shimmer.swift" <<'EXTRACT'
from pathlib import Path
import sys
source = Path("Sources/AgentWorkbench/ConversationActivityBar.swift").read_text()
start = source.index("struct ShimmerGlint: NSViewRepresentable")
end = source.index("/// When the turn last showed progress", start)
Path(sys.argv[1]).write_text("import AppKit\nimport SwiftUI\nimport QuartzCore\n" + source[start:end])
EXTRACT
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx26.0" \
    Sources/AgentWorkbench/PerchBusyIndicator.swift "$check_dir/Shimmer.swift" Tests/IdleRenderingChecks/App.swift \
    -o "$check_dir/IdleRenderingChecks"
"$check_dir/IdleRenderingChecks"
