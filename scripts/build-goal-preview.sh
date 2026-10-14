#!/bin/bash
# Native production goal component with isolated sample data; no remote connections.
set -euo pipefail
cd "$(dirname "$0")/.."
bin_dir="$(swift build --build-system native -c release --show-bin-path)"
app_dir="$PWD/build/Perch Goal Preview.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp -R Resources/Localization/*.lproj "$app_dir/Contents/Resources/"
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    while IFS= read -r file; do objects+=("$file"); done < <(find "$bin_dir/$target.build" -type f -name '*.o')
done
swiftc -target "$(uname -m)-apple-macosx26.0" -O -swift-version 5 -parse-as-library -I "$bin_dir/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include \
    Sources/AgentWorkbench/GoalHeaderBar.swift Sources/AgentWorkbench/WorkbenchTheme.swift \
    Sources/AgentWorkbench/UILocalization.swift Tests/GoalHeaderPreview/App.swift \
    "${objects[@]}" -o "$app_dir/Contents/MacOS/GoalHeaderPreview"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.perch.goalpreview</string>
<key>CFBundleName</key><string>Perch Goal Preview</string>
<key>CFBundleExecutable</key><string>GoalHeaderPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
