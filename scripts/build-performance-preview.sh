#!/bin/bash
# Independent baseline/current local pipeline fixture. Does not launch either app.
set -euo pipefail
cd "$(dirname "$0")/.."
variant="${1:-}"
case "$variant" in
    baseline) title="Baseline" ;;
    current) title="Current" ;;
    *) printf 'Usage: %s baseline|current [source-ref label]\n' "$0" >&2; exit 2 ;;
esac
# Optional: build the current variant from a committed revision under its own label,
# so two revisions of this branch can be compared directly in alternating order.
source_ref="${2:-}"
label="${3:-$variant}"
if [[ -n "$source_ref" ]]; then
    [[ "$variant" == current ]] || { printf 'A source ref applies only to the current variant\n' >&2; exit 2; }
    title="$(printf '%s' "${label:0:1}" | tr '[:lower:]' '[:upper:]')${label:1}"
fi
baseline_ref="${WORKBENCH_BASELINE_REF:-5596b6c4184c17f80f7992b11e6f1b8d647e46d8}"
if [[ "$variant" == baseline ]] && ! git cat-file -e "$baseline_ref^{commit}" 2>/dev/null; then
    printf 'Baseline commit is unavailable. Set WORKBENCH_BASELINE_REF to a local compatible commit.\n' >&2
    exit 2
fi
repo_root="$PWD"
snapshot_root="$PWD/.local/performance-sources/$label"
module_dir="$snapshot_root/Modules"
app_dir="$PWD/build/Performance $title.app"
bin_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$module_dir" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
app_files=(
    Sources/AgentWorkbench/ConversationTranscriptView.swift
    Sources/AgentWorkbench/ConversationScrollControls.swift
    Sources/AgentWorkbench/ReplyMarkdownView.swift
    Sources/AgentWorkbench/KimiAttachmentView.swift
    Sources/AgentWorkbench/ConversationActivityBar.swift
    Sources/AgentWorkbench/WorkbenchGlass.swift
    Sources/AgentWorkbench/WorkspaceSplitView.swift
)
# The historical baseline predates the extracted tool component.
if [[ "$variant" == current ]]; then app_files+=(Sources/AgentWorkbench/ToolActivityView.swift); fi
# Refresh only this fixture's copied source directory, never any checkout.
rm -rf "$snapshot_root/Sources"
if [[ "$variant" == baseline ]]; then
    git archive "$baseline_ref" Sources/WorkbenchCore "${app_files[@]}" | tar -x -C "$snapshot_root"
elif [[ -n "$source_ref" ]]; then
    git archive "$source_ref" Sources/WorkbenchCore "${app_files[@]}" | tar -x -C "$snapshot_root"
else
    mkdir -p "$snapshot_root/Sources/AgentWorkbench"
    cp -R Sources/WorkbenchCore "$snapshot_root/Sources/WorkbenchCore"
    for path in "${app_files[@]}"; do cp "$path" "$snapshot_root/$path"; done
fi
python3 - "$label" "$baseline_ref" "$snapshot_root" "$app_dir/Contents/Resources/build.json" "$repo_root" "$variant" "$source_ref" <<'PY'
import hashlib, json, pathlib, subprocess, sys
variant, baseline, snapshot, output, repo, kind, source_ref = sys.argv[1:]
root = pathlib.Path(snapshot)
hash = hashlib.sha256()
for path in sorted((root / 'Sources').rglob('*.swift')):
    hash.update(str(path.relative_to(root)).encode()); hash.update(path.read_bytes())
fixture_hash = hashlib.sha256()
for path in sorted(pathlib.Path('Tests/PerformancePreview').glob('*.swift')):
    fixture_hash.update(path.name.encode()); fixture_hash.update(path.read_bytes())
metadata = {
    'variant': variant, 'baseline_commit': baseline,
    'source_commit': baseline if kind == 'baseline' else subprocess.check_output(
        ['git', 'rev-parse', source_ref or 'HEAD'], text=True).strip(),
    'source_sha256': hash.hexdigest(), 'fixture_sha256': fixture_hash.hexdigest(),
    'package_resolved_sha256': hashlib.sha256(pathlib.Path('Package.resolved').read_bytes()).hexdigest(),
    'compiler': subprocess.check_output(['swift', '--version'], text=True).strip(),
    'macos': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
    'results_dir': str(pathlib.Path(repo) / '.local/performance-results'),
}
pathlib.Path(output).write_text(json.dumps(metadata, indent=2))
PY
includes=( -I "$bin_dir/Modules" -I .build/checkouts/swift-markdown/Sources/CAtomic/include -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include )
# Compile the complete matching Core instead of accidentally linking baseline UI
# against a current WorkbenchCore. Dependency objects are identical for both apps.
swiftc -O -swift-version 5 -parse-as-library -whole-module-optimization \
    -emit-object -emit-module -module-name WorkbenchCore \
    -emit-module-path "$module_dir/WorkbenchCore.swiftmodule" \
    "${includes[@]}" "$snapshot_root"/Sources/WorkbenchCore/*.swift -o "$module_dir/WorkbenchCore.o"
objects=( "$module_dir/WorkbenchCore.o" )
for target in Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    while IFS= read -r file; do objects+=("$file"); done < <(rg --files --hidden --no-ignore "$bin_dir/$target.build" | rg '\.o$' | sort)
done
compile_flags=( -D PERFORMANCE_CURRENT )
if [[ "$variant" == baseline ]]; then compile_flags=( -D PERFORMANCE_BASELINE ); fi
copied_app_files=()
for path in "${app_files[@]}"; do copied_app_files+=("$snapshot_root/$path"); done
swiftc -O -swift-version 5 -parse-as-library "${compile_flags[@]}" -I "$module_dir" "${includes[@]}" \
    "${copied_app_files[@]}" Tests/PerformancePreview/Workload.swift Tests/PerformancePreview/App.swift \
    "${objects[@]}" -o "$app_dir/Contents/MacOS/PerformancePreview"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentworkbench.performance.$label</string>
<key>CFBundleName</key><string>Performance $title</string>
<key>CFBundleExecutable</key><string>PerformancePreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
