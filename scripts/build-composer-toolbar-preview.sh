#!/bin/bash
# Standalone native visual fixture. No hosts, workspace state, or remote agents are loaded.
set -euo pipefail
cd "$(dirname "$0")/.."
bin_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/build/Composer Toolbar Preview.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp -R Resources/Localization/*.lproj "$app_dir/Contents/Resources/"
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    while IFS= read -r file; do objects+=("$file"); done < <(rg --files --hidden --no-ignore "$bin_dir/$target.build" | rg '\.o$')
done
swiftc -O -swift-version 5 -parse-as-library -I "$bin_dir/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include \
    Sources/AgentWorkbench/MessageComposer.swift Sources/AgentWorkbench/CommandPalette.swift Sources/AgentWorkbench/ModelPicker.swift \
    Sources/AgentWorkbench/ThinkingPicker.swift Sources/AgentWorkbench/ComposerActionButton.swift Sources/AgentWorkbench/WorkbenchGlass.swift \
    Tests/ComposerToolbarPreview/App.swift \
    "${objects[@]}" -o "$app_dir/Contents/MacOS/ComposerToolbarPreview"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.agentworkbench.composertoolbarpreview</string>
<key>CFBundleName</key><string>Composer Toolbar Preview</string>
<key>CFBundleExecutable</key><string>ComposerToolbarPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
