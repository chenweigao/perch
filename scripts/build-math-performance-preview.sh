#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
variant="${1:?variant required}"
revision="${2:-HEAD}"
case "$variant" in baseline|candidate) ;; *) exit 2 ;; esac
snapshot="$PWD/.local/math-performance-sources/$variant"
app_dir="$PWD/build/Math Performance $variant.app"
if [ -e "$snapshot" ] || [ -e "$app_dir" ]; then
    printf 'Use a fresh output directory for each build\n' >&2
    exit 2
fi
mkdir -p "$snapshot" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
git archive "$revision" Sources/WorkbenchCore | tar -x -C "$snapshot"
mkdir -p "$snapshot/Sources/AgentWorkbench"
for name in WorkbenchTheme CodeHighlighting ReplyMarkdownView NativeAssistantBlocks ReplyMathView ReplyAlertBlock ReplySelection ReplyMermaid PerfDiagnostics ImagePreviewPanel ConversationReadingMemory ConversationActions ConversationBookmarksStore; do
    git show "$revision:Sources/AgentWorkbench/${name}.swift" > "$snapshot/Sources/AgentWorkbench/${name}.swift"
done
python3 - "$snapshot" "$app_dir" "$variant" "$revision" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
snapshot, app, variant, revision = sys.argv[1:]
resolved = json.loads(subprocess.check_output(['git', 'show', revision + ':Package.resolved'], text=True))
pins = {pin['identity']: pin for pin in resolved['pins']}
selected = [pins[name] for name in ['swift-markdown', 'swift-cmark', 'swiftmath']]
dependencies = ',\n    '.join('.package(url: ' + json.dumps(pin['location']) + ', exact: ' + json.dumps(pin['state']['version']) + ')' for pin in selected)
package = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MathPerformance", platforms: [.macOS("26.0")], dependencies: [
    ''' + dependencies + '''
], targets: [.target(name: "WorkbenchCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")])], swiftLanguageModes: [.v5])
'''
(Path(snapshot) / 'Package.swift').write_text(package)
metadata = {'variant': variant, 'revision': subprocess.check_output(['git', 'rev-parse', revision], text=True).strip(),
            'fixture': 'synthetic; no sessions or network',
            'dependencies': {pin['identity']: pin['state'] for pin in selected},
            'suffix_search': 'private static func closingDelimiter' in (Path(snapshot) / 'Sources/WorkbenchCore/ReplyMath.swift').read_text(),
            'toolchain': subprocess.check_output(['swift', '--version'], text=True).strip()}
# Fingerprint the exported inputs, not the commit or output paths. Unrelated
# changes must not turn an A/A measurement into a source-regression claim.
# Both variants use this harness; candidate-only contract counters are intentional.
digest = hashlib.sha256()
inputs = [(str(path.relative_to(snapshot)), path.read_bytes())
          for path in sorted(Path(snapshot).rglob('*.swift'))]
inputs += [(name, Path(name).read_bytes()) for name in
           ['Tests/MathPerformancePreview/App.swift', 'scripts/build-math-performance-preview.sh']]
inputs += [('dependencies', json.dumps(selected, sort_keys=True).encode()),
           ('toolchain', metadata['toolchain'].encode())]
for name, data in inputs:
    digest.update(name.encode() + b'\0' + data + b'\0')
metadata['source_input_sha256'] = digest.hexdigest()
(Path(app) / 'Contents/Resources/build.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
swift build --package-path "$snapshot" --build-system native -c release --target SwiftMath
swift build --package-path "$snapshot" --build-system native -c release --target WorkbenchCore
bin_dir="$(swift build --package-path "$snapshot" --build-system native -c release --show-bin-path)"
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions SwiftMath; do
    while IFS= read -r file; do objects+=("$file"); done < <(python3 - "$bin_dir/$target.build" <<'PY'
from pathlib import Path
import sys
for path in sorted(Path(sys.argv[1]).rglob('*.o')):
    print(path)
PY
)
done
flags=(-D MATH_PERFORMANCE_BASELINE)
if [ "$variant" = candidate ]; then flags=(-D MATH_PERFORMANCE_CHECKS); fi
swiftc -target "$(uname -m)-apple-macosx26.0" -O -swift-version 5 -parse-as-library \
    "${flags[@]}" -I "$bin_dir/Modules" \
    -I "$snapshot/.build/checkouts/swift-markdown/Sources/CAtomic/include" \
    -I "$snapshot/.build/checkouts/swift-cmark/src/include" \
    -I "$snapshot/.build/checkouts/swift-cmark/extensions/include" \
    "$snapshot"/Sources/AgentWorkbench/*.swift Tests/MathPerformancePreview/App.swift \
    "${objects[@]}" -o "$app_dir/Contents/MacOS/MathPerformance"
cp -R "$bin_dir/SwiftMath_SwiftMath.bundle" "$app_dir/Contents/Resources/"
python3 - "$app_dir" "$variant" <<'PY'
from pathlib import Path
import plistlib
import sys
app, variant = sys.argv[1:]
with (Path(app) / 'Contents/Info.plist').open('wb') as handle:
    plistlib.dump({'CFBundleIdentifier': 'dev.agentworkbench.mathperformance.' + variant,
                  'CFBundleName': 'Math Performance ' + variant, 'CFBundleExecutable': 'MathPerformance',
                  'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True}, handle)
PY
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
