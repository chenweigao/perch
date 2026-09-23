#!/bin/bash
# Standalone native visual fixture. No hosts, workspace state, or remote agents are loaded.
set -euo pipefail
cd "$(dirname "$0")/.."
bin_dir="$(swift build --build-system native -c release --show-bin-path)"
app_dir="$PWD/build/Reply Reading Preview.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    while IFS= read -r file; do objects+=("$file"); done < <(rg --files --hidden --no-ignore "$bin_dir/$target.build" | rg '\.o$')
done
swiftc -O -swift-version 5 -parse-as-library -I "$bin_dir/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include \
    Sources/AgentWorkbench/ReplyMarkdownView.swift Sources/AgentWorkbench/ConversationTranscriptView.swift Sources/AgentWorkbench/ConversationReadingMemory.swift Sources/AgentWorkbench/ActivitySummarySettings.swift Sources/AgentWorkbench/ActivitySummaryController.swift \
    Sources/AgentWorkbench/ToolActivityView.swift Sources/AgentWorkbench/KimiAttachmentView.swift Sources/AgentWorkbench/ModelPicker.swift \
    Sources/AgentWorkbench/ConversationScrollControls.swift Sources/AgentWorkbench/WorkbenchGlass.swift \
    Sources/AgentWorkbench/ConversationActivityBar.swift Tests/ReadingPreview/App.swift \
    "${objects[@]}" -o "$app_dir/Contents/MacOS/ReplyReadingPreview"
cp Tests/Fixtures/reply-reading.md "$app_dir/Contents/Resources/"
# Private snapshots stay in ignored build output and are never required by the fixture.
if [[ -n "${READING_SNAPSHOT:-}" ]]; then
    cp "$READING_SNAPSHOT" "$app_dir/Contents/Resources/scroll-snapshot.json"
else
    rm -f "$app_dir/Contents/Resources/scroll-snapshot.json"
fi
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentworkbench.readingpreview</string>
<key>CFBundleName</key><string>Reply Reading Preview</string>
<key>CFBundleExecutable</key><string>ReplyReadingPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
