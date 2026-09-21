#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Explicit workaround for this Mac's mixed CLT install: its private package
# interfaces are from 2024 while public interfaces and libraries are Swift 6.3.
# Work only on a local copy, never on the system toolchain.
mkdir -p .local/swiftpm-libs
cp -R /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI .local/swiftpm-libs/
cp -R /Library/Developer/CommandLineTools/usr/lib/swift/pm/PluginAPI .local/swiftpm-libs/
python3 - <<'PY'
from pathlib import Path
for path in Path('.local/swiftpm-libs').rglob('*.private.swiftinterface'):
    path.unlink()
PY
echo "Use SWIFTPM_CUSTOM_LIBS_DIR=\"$PWD/.local/swiftpm-libs\" for this Mac's builds."
