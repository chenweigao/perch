#!/bin/bash
# Uses the production native split view and sidebar shell, without loading sessions.
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="$PWD/build/Sidebar Preview.app"
mkdir -p "$app_dir/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library \
    Sources/AgentWorkbench/WorkspaceSplitView.swift Sources/AgentWorkbench/WorkspaceSidebarShell.swift \
    Sources/AgentWorkbench/SessionRowChrome.swift Tests/SidebarPreview/App.swift -o "$app_dir/Contents/MacOS/SidebarPreview"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentworkbench.sidebarpreview</string>
<key>CFBundleName</key><string>Sidebar Preview</string>
<key>CFBundleExecutable</key><string>SidebarPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
