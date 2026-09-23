#!/bin/bash
# Standalone native visual fixture. No hosts, workspace state, or remote agents are loaded.
set -euo pipefail
cd "$(dirname "$0")/.."
bin_dir="$(swift build --build-system native -c release --show-bin-path)"
fixture=Tests/ToolVisibilityPreview/App.swift
app_name="Tool Visibility Preview"
bundle_id=dev.agentworkbench.toolvisibilitypreview
if [[ "${1:-}" == "--summary-duplicate" ]]; then
    fixture=Tests/SummaryDuplicatePreview/App.swift
    app_name="Summary Duplicate Preview"
    bundle_id=dev.agentworkbench.summaryduplicatepreview
fi
app_dir="$PWD/build/$app_name.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp -R Resources/Localization/*.lproj "$app_dir/Contents/Resources/"
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    while IFS= read -r file; do objects+=("$file"); done < <(rg --files --hidden --no-ignore "$bin_dir/$target.build" | rg '\.o$')
done
swiftc -O -swift-version 5 -parse-as-library -I "$bin_dir/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include \
    Sources/AgentWorkbench/ReplyMarkdownView.swift Sources/AgentWorkbench/ConversationTranscriptView.swift Sources/AgentWorkbench/ConversationReadingMemory.swift Sources/AgentWorkbench/ActivitySummarySettings.swift Sources/AgentWorkbench/ActivitySummaryController.swift \
    Sources/AgentWorkbench/ToolActivityView.swift Sources/AgentWorkbench/KimiAttachmentView.swift Sources/AgentWorkbench/ModelPicker.swift Sources/AgentWorkbench/ThinkingPicker.swift \
    Sources/AgentWorkbench/ConversationScrollControls.swift Sources/AgentWorkbench/WorkbenchGlass.swift \
    Sources/AgentWorkbench/UILocalization.swift Sources/AgentWorkbench/ConversationActivityBar.swift "$fixture" \
    "${objects[@]}" -o "$app_dir/Contents/MacOS/ToolVisibilityPreview"
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>$app_name</string>
<key>CFBundleExecutable</key><string>ToolVisibilityPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
