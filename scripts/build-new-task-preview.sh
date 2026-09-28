#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# NewTaskView pulls in the whole workbench model; reuse the release objects.
bin_dir="$PWD/.build/arm64-apple-macosx/release"
if [ ! -d "$bin_dir/Modules" ]; then
    echo "run scripts/build.sh first" >&2
    exit 1
fi
ghostty="$PWD/.build/artifacts/libghostty-spm/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64"
app_dir="$PWD/build/NewTask Preview.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp -R Resources/Localization/*.lproj "$app_dir/Contents/Resources/"
swiftc -Onone -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -I "$bin_dir/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include \
    -I .build/checkouts/swift-cmark/extensions/include \
    -I "$ghostty/Headers" \
    $(ls Sources/AgentWorkbench/*.swift | grep -v WorkbenchApp.swift) \
    Tests/NewTaskPreview/App.swift \
    "$bin_dir"/WorkbenchCore.build/*.o "$bin_dir"/Markdown.build/*.o "$bin_dir"/CAtomic.build/*.o \
    "$bin_dir"/cmark_gfm.build/*.o "$bin_dir"/cmark_gfm_extensions.build/*.o \
    "$bin_dir"/GhosttyTerminal.build/*.o "$bin_dir"/GhosttyKit.build/*.o "$bin_dir"/MSDisplayLink.build/*.o \
    "$ghostty/libghostty.a" -lc++ -framework Carbon -framework Metal -framework QuartzCore \
    -o "$app_dir/Contents/MacOS/NewTaskPreview"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentworkbench.newtaskpreview</string>
<key>CFBundleName</key><string>NewTask Preview</string>
<key>CFBundleExecutable</key><string>NewTaskPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
