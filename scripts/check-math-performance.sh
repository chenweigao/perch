#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:?output directory required}"
baseline="$(python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess
baseline = os.environ.get('WORKBENCH_MATH_BASELINE_REF')
event_path = os.environ.get('GITHUB_EVENT_PATH')
if not baseline and event_path:
    event = json.loads(Path(event_path).read_text())
    baseline = event.get('pull_request', {}).get('base', {}).get('sha') or event.get('before')
    if baseline and set(baseline) == {'0'}:
        baseline = None
baseline = baseline or 'HEAD^'
print(subprocess.check_output(['git', 'rev-parse', '--verify', '--end-of-options', baseline + '^{commit}'], text=True).strip())
PY
)"
bash scripts/build-math-performance-preview.sh baseline "$baseline"
bash scripts/build-math-performance-preview.sh candidate HEAD
python3 scripts/run-math-performance.py \
    --baseline-app 'build/Math Performance baseline.app' \
    --candidate-app 'build/Math Performance candidate.app' \
    --output "$output"
