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
math_patch="$snapshot/patches/swiftmath-app-resources.patch"
if git cat-file -e "$revision:patches/swiftmath-app-resources.patch" 2>/dev/null; then
    mkdir -p "$snapshot/patches"
    git show "$revision:patches/swiftmath-app-resources.patch" > "$math_patch"
fi
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
patch_path = Path(snapshot) / 'patches/swiftmath-app-resources.patch'
patch_bytes = patch_path.read_bytes() if patch_path.exists() else b''
metadata['swiftmath_patch_sha256'] = hashlib.sha256(patch_bytes).hexdigest() if patch_path.exists() else None
inputs += [('patches/swiftmath-app-resources.patch', patch_bytes),
           ('dependencies', json.dumps(selected, sort_keys=True).encode()),
           ('toolchain', metadata['toolchain'].encode())]
for name, data in inputs:
    digest.update(name.encode() + b'\0' + data + b'\0')
metadata['source_input_sha256'] = digest.hexdigest()
(Path(app) / 'Contents/Resources/build.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
checkouts_dir="$snapshot/.build/checkouts"
bin_dir=""
if [ "${PERCH_REUSE_PREBUILT:-0}" = "1" ] && git diff --quiet "$revision" HEAD -- Sources/WorkbenchCore Package.resolved patches/swiftmath-app-resources.patch 2>/dev/null; then
    candidate_bin="$(swift build --build-system native -c release --show-bin-path 2>/dev/null || true)"
    patch_matches=0
    if [ ! -e "$math_patch" ] || git -C "$PWD/.build/checkouts/SwiftMath" apply --reverse --check "$math_patch" 2>/dev/null; then
        patch_matches=1
    fi
    if [ "$patch_matches" = "1" ] && [ -n "$candidate_bin" ] && [ -e "$candidate_bin/Modules/WorkbenchCore.swiftmodule" ] && [ -e "$candidate_bin/Modules/SwiftMath.swiftmodule" ] && [ -d "$candidate_bin/WorkbenchCore.build" ] && [ -d "$candidate_bin/SwiftMath.build" ] && [ -d "$PWD/.build/checkouts/swift-markdown/Sources/CAtomic/include" ]; then
        bin_dir="$candidate_bin"
        checkouts_dir="$PWD/.build/checkouts"
    fi
fi
if [ -z "$bin_dir" ]; then
    swift package --package-path "$snapshot" resolve
    if [ -e "$math_patch" ] && ! git -C "$checkouts_dir/SwiftMath" apply --reverse --check "$math_patch" 2>/dev/null; then
        git -C "$checkouts_dir/SwiftMath" apply --check "$math_patch"
        git -C "$checkouts_dir/SwiftMath" apply "$math_patch"
    fi
    swift build --package-path "$snapshot" --build-system native -c release --target SwiftMath
    swift build --package-path "$snapshot" --build-system native -c release --target WorkbenchCore
    bin_dir="$(swift build --package-path "$snapshot" --build-system native -c release --show-bin-path)"
fi
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
swiftc -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)" -target "$(uname -m)-apple-macosx26.0" -O -swift-version 5 -parse-as-library \
    "${flags[@]}" -I "$bin_dir/Modules" \
    -I "$checkouts_dir/swift-markdown/Sources/CAtomic/include" \
    -I "$checkouts_dir/swift-cmark/src/include" \
    -I "$checkouts_dir/swift-cmark/extensions/include" \
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
