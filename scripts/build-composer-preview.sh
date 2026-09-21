#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="$PWD/build/Composer Preview.app"
mkdir -p "$app_dir/Contents/MacOS"
swiftc -swift-version 5 -parse-as-library Sources/AgentWorkbench/MessageComposer.swift Tests/ComposerPreview/App.swift -o "$app_dir/Contents/MacOS/ComposerPreview"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentworkbench.composerpreview</string>
<key>CFBundleName</key><string>Composer Preview</string>
<key>CFBundleExecutable</key><string>ComposerPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
