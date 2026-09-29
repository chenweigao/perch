#!/bin/bash
# Standalone synthetic preview: no saved hosts or remote connections.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-navigation-preview.sh
app="$PWD/build/Perch Long Output Preview.app"
ditto "build/Navigation Preview.app" "$app"
python3 - "$app" <<'PY'
from pathlib import Path
import plistlib, sys
p = Path(sys.argv[1]) / 'Contents/Info.plist'
info = plistlib.loads(p.read_bytes())
info.update(CFBundleIdentifier='dev.perch.longoutputpreview',
            CFBundleName='Perch Long Output Preview', PerchLongOutputDemo=True)
p.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
