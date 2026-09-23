#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bin_dir="$(swift build --build-system native -c release --show-bin-path)"
app="$PWD/build/Host Identity Preview.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
objects=()
for target in WorkbenchCore Markdown CAtomic cmark_gfm cmark_gfm_extensions; do
    while IFS= read -r file; do objects+=("$file"); done < <(rg --files --hidden --no-ignore "$bin_dir/$target.build" | rg '\.o$')
done
swiftc -O -swift-version 5 -parse-as-library -I "$bin_dir/Modules" \
    -I .build/checkouts/swift-markdown/Sources/CAtomic/include \
    -I .build/checkouts/swift-cmark/src/include -I .build/checkouts/swift-cmark/extensions/include \
    Sources/AgentWorkbench/UILocalization.swift Sources/AgentWorkbench/HostIdentityIcon.swift Sources/AgentWorkbench/SessionRowChrome.swift Tests/HostLabelPreview/App.swift \
    "${objects[@]}" -o "$app/Contents/MacOS/HostLabelPreview"
cp -R Resources/Localization/*.lproj "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.perch.host-identity-preview</string>
<key>CFBundleName</key><string>Host Identity Preview</string>
<key>CFBundleExecutable</key><string>HostLabelPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
