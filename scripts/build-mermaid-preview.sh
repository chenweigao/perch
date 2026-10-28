#!/bin/bash
# Mermaid diagram rendering fixture. No hosts, workspace state, or remote agents are loaded.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native -c release --target WorkbenchCore >/dev/null
swift build --build-system native -c release --target SwiftMath >/dev/null
bin_dir="$(swift build --build-system native -c release --show-bin-path)"
app_dir="$PWD/build/Mermaid Preview.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
scripts/prepare-highlight.sh "$app_dir/Contents/Resources"
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions SwiftMath; do
    while IFS= read -r file; do objects+=("$file"); done < <(rg --files --hidden --no-ignore "$bin_dir/$target.build" | rg '\.o$')
done
swiftc -target "$(uname -m)-apple-macosx26.0" -O -swift-version 5 -parse-as-library -I "$bin_dir/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include \
    Sources/AgentWorkbench/WorkbenchTheme.swift Sources/AgentWorkbench/CodeHighlighting.swift Sources/AgentWorkbench/ReplyMarkdownView.swift Sources/AgentWorkbench/NativeAssistantBlocks.swift \
    Sources/AgentWorkbench/ReplyMathView.swift Sources/AgentWorkbench/ReplyAlertBlock.swift Sources/AgentWorkbench/RevealFrameDriver.swift Sources/AgentWorkbench/ReplySelection.swift \
    Sources/AgentWorkbench/ConversationReadingMemory.swift Sources/AgentWorkbench/ConversationActions.swift Sources/AgentWorkbench/ConversationBookmarksStore.swift \
    Sources/AgentWorkbench/ReplyMermaid.swift Sources/AgentWorkbench/PerfDiagnostics.swift Sources/AgentWorkbench/ImagePreviewPanel.swift \
    Tests/MermaidPreview/App.swift \
    "${objects[@]}" -o "$app_dir/Contents/MacOS/MermaidPreview"
cp -R "$bin_dir/SwiftMath_SwiftMath.bundle" "$app_dir/Contents/Resources/"
if [ -f Resources/Mermaid/mermaid.min.js ]; then
    cp Resources/Mermaid/mermaid.min.js "$app_dir/Contents/Resources/"
fi
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentworkbench.mermaidpreview</string>
<key>CFBundleName</key><string>Mermaid Preview</string>
<key>CFBundleExecutable</key><string>MermaidPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
