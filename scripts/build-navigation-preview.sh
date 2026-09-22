#!/bin/bash
# Isolated click-response and scroll fixture. Own bundle ID and results directory;
# it never launches Perch, reads saved hosts or contacts a remote agent.
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="$PWD/build/Navigation Preview.app"
# This fixture links SwiftPM object files directly. Use the native layout;
# Xcode 27 defaults to Swift Build, whose Products directory has no .build objects.
swift build --build-system native -c release --target WorkbenchCore
bin_dir="$(swift build --build-system native -c release --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
app_files=(
    Sources/AgentWorkbench/ToolActivityView.swift
    Sources/AgentWorkbench/ConversationTranscriptView.swift Sources/AgentWorkbench/ConversationReadingMemory.swift Sources/AgentWorkbench/ActivitySummarySettings.swift Sources/AgentWorkbench/ActivitySummaryController.swift
    Sources/AgentWorkbench/ConversationScrollControls.swift
    Sources/AgentWorkbench/ReplyMarkdownView.swift
    Sources/AgentWorkbench/KimiAttachmentView.swift
    Sources/AgentWorkbench/ConversationActivityBar.swift
    Sources/AgentWorkbench/WorkbenchGlass.swift
    Sources/AgentWorkbench/MessageComposer.swift
)
includes=( -I "$bin_dir/Modules" -I .build/checkouts/swift-markdown/Sources/CAtomic/include
           -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include )
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    while IFS= read -r file; do objects+=("$file"); done < <(rg --files --hidden --no-ignore "$bin_dir/$target.build" | rg '\.o$' | sort)
done
swiftc -O -swift-version 5 -D TRANSCRIPT_CHECKS -parse-as-library "${includes[@]}" \
    "${app_files[@]}" Tests/PerformancePreview/Workload.swift \
    Tests/NavigationPreview/History.swift Tests/NavigationPreview/JointInteraction.swift Tests/NavigationPreview/App.swift \
    "${objects[@]}" -o "$app_dir/Contents/MacOS/NavigationPreview"
commit="$(git rev-parse HEAD)"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentworkbench.navigationqa</string>
<key>CFBundleName</key><string>Navigation Preview</string>
<key>CFBundleExecutable</key><string>NavigationPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>PerchSourceCommit</key><string>$commit</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$app_dir/Contents/Resources/build.json" "${app_files[@]}" <<'PYMETA'
import hashlib, json, pathlib, subprocess, sys

def digest(paths):
    result = hashlib.sha256()
    for path in sorted(paths):
        result.update(str(path).encode()); result.update(path.read_bytes())
    return result.hexdigest()

sources = [pathlib.Path(p) for p in sys.argv[2:]] + list(pathlib.Path('Sources/WorkbenchCore').glob('*.swift'))
fixtures = list(pathlib.Path('Tests/NavigationPreview').glob('*.swift')) + [pathlib.Path('Tests/PerformancePreview/Workload.swift')]
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'source_sha256': digest(sources), 'fixture_sha256': digest(fixtures),
    'package_resolved_sha256': digest([pathlib.Path('Package.resolved')]),
    'compiler': subprocess.check_output(['swift', '--version'], text=True).strip(),
}, indent=2))
PYMETA
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
