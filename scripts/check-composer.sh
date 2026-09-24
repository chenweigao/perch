#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .local
work="$(mktemp -d "$PWD/.local/composer-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 5 Sources/AgentWorkbench/MessageComposer.swift Tests/ComposerChecks/main.swift -o "$work/compiled"
# Match the isolated app launch used by the host lifecycle checks.
# Require both normal process exit and the receipt written after all assertions.
app="$work/ComposerChecks.app"
mkdir -p "$app/Contents/MacOS"
cp "$work/compiled" "$app/Contents/MacOS/ComposerChecks"
python3 - "$app" <<'PY'
from pathlib import Path
import plistlib
import sys
import uuid
app = Path(sys.argv[1])
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'dev.perch.composerchecks.' + uuid.uuid4().hex,
    'CFBundleName': 'Composer Checks', 'CFBundleExecutable': 'ComposerChecks',
    'CFBundlePackageType': 'APPL', 'LSUIElement': True,
}))
PY
codesign --force --sign - "$app"
python3 - "$app" "$work/result.json" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path
app, receipt = map(Path, sys.argv[1:])
subprocess.run([str(app / 'Contents/MacOS/ComposerChecks')], check=True, timeout=30,
               env=dict(os.environ, COMPOSER_CHECK_RESULT=str(receipt)))
result = json.loads(receipt.read_text())
assert result['status'] == 'passed', result
PY
