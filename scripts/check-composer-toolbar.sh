#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-composer-toolbar-preview.sh
output="$PWD/.local/composer-toolbar-checks"
mkdir -p "$output"
for agent in kimi omp dsh codex qoder; do
    result="$output/$agent.json"
    rm -f "$result" "$output/$agent.log" "$output/$agent-error.log"
    open -n -W --env COMPOSER_TOOLBAR_CHECKS=1 --env "COMPOSER_PREVIEW_AGENT=$agent" \
        --env "COMPOSER_TOOLBAR_RESULT=$result" --stdout "$output/$agent.log" \
        --stderr "$output/$agent-error.log" "build/Composer Toolbar Preview.app"
    python3 - "$result" <<'PY'
import json
import sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
print(result)
assert result['status'] == 'passed', result
PY
done
