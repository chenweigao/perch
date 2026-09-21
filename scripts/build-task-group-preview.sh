#!/bin/bash
# Standalone native visual fixture. No hosts, workspace state, or remote agents are loaded.
set -euo pipefail
cd "$(dirname "$0")/.."
build_root="${WORKBENCH_PREVIEW_BUILD_ROOT:-$PWD}"
bin_dir="$(swift build --package-path "$build_root" -c release --show-bin-path)"
app_dir="$PWD/build/Task Group Preview.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    while IFS= read -r file; do objects+=("$file"); done < <(rg --files --hidden --no-ignore "$bin_dir/$target.build" | rg '\.o$')
done
swiftc -O -swift-version 5 -parse-as-library -I "$bin_dir/Modules" \
    -I "$build_root"/.build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I "$build_root"/.build/checkouts/swift-cmark/src/include -I "$build_root"/.build/checkouts/swift-cmark/extensions/include \
    Sources/AgentWorkbench/UILocalization.swift Sources/AgentWorkbench/WorkbenchDashboard.swift \
    Sources/AgentWorkbench/SessionStatusIndicator.swift Sources/AgentWorkbench/ConversationActivityBar.swift \
    Sources/AgentWorkbench/BatchArchiveControls.swift Sources/AgentWorkbench/WorkbenchGlass.swift \
    Sources/AgentWorkbench/WorkspaceSplitView.swift Sources/AgentWorkbench/WorkspaceSidebarShell.swift \
    Sources/AgentWorkbench/TaskGroupPage.swift Sources/AgentWorkbench/WorkItemGroupEditor.swift \
    Tests/TaskGroupPreview/App.swift \
    "${objects[@]}" -o "$app_dir/Contents/MacOS/TaskGroupPreview"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentworkbench.taskgrouppreview</string>
<key>CFBundleName</key><string>Task Group Preview</string>
<key>CFBundleExecutable</key><string>TaskGroupPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp -R Resources/Localization/*.lproj "$app_dir/Contents/Resources/"
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
