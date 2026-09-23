#!/bin/bash
# Uses the production native split view and sidebar shell, without loading sessions.
set -euo pipefail
cd "$(dirname "$0")/.."
app_dir="$PWD/build/Sidebar Preview.app"
swift build --build-system native -c release --target WorkbenchCore
bin_dir="$(swift build --build-system native -c release --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    objects+=("$bin_dir/$target.build/"*.o)
done
swiftc -O -swift-version 5 -parse-as-library -I "$bin_dir/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include \
    Sources/AgentWorkbench/UILocalization.swift Sources/AgentWorkbench/WorkspaceSplitView.swift Sources/AgentWorkbench/WorkspaceSidebarShell.swift \
    Sources/AgentWorkbench/HostIdentityIcon.swift Sources/AgentWorkbench/SessionRowChrome.swift \
    Tests/SidebarPreview/App.swift Tests/SidebarPreview/Checks.swift "${objects[@]}" -o "$app_dir/Contents/MacOS/SidebarPreview"
cp -R Resources/Localization/*.lproj "$app_dir/Contents/Resources/"
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
if [[ "${1:-}" == "--check" ]]; then
    for mode in collapse restore; do
        SIDEBAR_CHECK_MODE="$mode" "$app_dir/Contents/MacOS/SidebarPreview" \
            -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO
    done
fi
