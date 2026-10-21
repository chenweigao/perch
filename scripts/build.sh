#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${WORKBENCH_BUILD_CONFIGURATION:-release}"
swift package resolve
patch_file="$PWD/patches/ghostty-app-resources.patch"
checkout="$PWD/.build/checkouts/libghostty-spm"
if ! git -C "$checkout" apply --reverse --check "$patch_file" 2>/dev/null; then
    git -C "$checkout" apply --check "$patch_file"
    git -C "$checkout" apply "$patch_file"
fi
# Swift 6.4's SwiftBuild backend stamps the deployment target as the linked SDK,
# which disables the native floating sidebar. Native preserves the actual SDK.
swift build --build-system native --configuration "$configuration"
bin_dir="$(swift build --build-system native --configuration "$configuration" --show-bin-path)"
app_dir="${WORKBENCH_APP_DIR:-$PWD/build/Perch.app}"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/AgentWorkbench" "$app_dir/Contents/MacOS/AgentWorkbench"
for bundle in "$bin_dir"/*.bundle; do
    cp -R "$bundle" "$app_dir/Contents/Resources/"
done
cp -R "$PWD/Resources/Localization/"*.lproj "$app_dir/Contents/Resources/"
# mermaid.min.js is not committed (a minified blob trips the source audit);
# fetch the pinned release on demand and verify its digest. Without it mermaid
# blocks degrade to plain code cards.
mermaid_js="Resources/Mermaid/mermaid.min.js"
if [ ! -f "$mermaid_js" ]; then
    curl -sL -o "$mermaid_js" https://cdn.jsdelivr.net/npm/mermaid@11.12.1/dist/mermaid.min.js || true
fi
if [ -f "$mermaid_js" ] && [ "$(shasum -a 256 "$mermaid_js" | cut -d ' ' -f 1)" = "198b19442f86f0b46a17e56d3abf744c3a28a3427e66fa8dada3b589a77babcc" ]; then
    cp "$mermaid_js" "$app_dir/Contents/Resources/mermaid.min.js"
else
    rm -f "$mermaid_js"
    echo "warning: Resources/Mermaid/mermaid.min.js unavailable or corrupt; mermaid diagrams render as code" >&2
fi
cp Resources/Brand/Perch.icns "$app_dir/Contents/Resources/Perch.icns"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
# Liquid Glass icon: compile the Icon Composer document into Assets.car. On
# macOS 26 the system prefers CFBundleIconName; the icns above stays as the
# flattened fallback for contexts that cannot read the compiled catalog.
icon_build="$PWD/build/icon"
rm -rf "$icon_build"
mkdir -p "$icon_build"
xcrun actool --compile "$icon_build" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon Perch --standalone-icon-behavior none \
    --output-partial-info-plist "$icon_build/partial.plist" \
    Resources/Brand/Perch.icon >/dev/null
cp "$icon_build/Assets.car" "$app_dir/Contents/Resources/Assets.car"
plutil -replace CFBundleIconName -string Perch "$app_dir/Contents/Info.plist"
# The marketing version lives in Resources/Info.plist; the build identity is stamped
# here so any bundle can be traced back to the commit it was built from. A checkout
# without Git metadata keeps the source values.
revision="$(git describe --tags --dirty --always 2>/dev/null || true)"
commits="$(git rev-list --count HEAD 2>/dev/null || true)"
if [ -n "$revision" ]; then
    plutil -replace PerchSourceRevision -string "$revision" "$app_dir/Contents/Info.plist"
fi
if [ -n "$commits" ]; then
    plutil -replace CFBundleVersion -string "$commits" "$app_dir/Contents/Info.plist"
fi
mkdir -p "$app_dir/Contents/Resources/RemoteSetup/scripts" "$app_dir/Contents/Resources/RemoteSetup/remote"
cp scripts/install-native-service.sh "$app_dir/Contents/Resources/RemoteSetup/scripts/"
cp remote/local-agent-service.py remote/native-agent-service.py remote/qoder-worker.mjs remote/claude-worker.mjs remote/package.json "$app_dir/Contents/Resources/RemoteSetup/remote/"

mkdir -p "$app_dir/Contents/Resources/Licenses"
cp .build/checkouts/libghostty-spm/LICENSE "$app_dir/Contents/Resources/Licenses/GhosttyKit.txt"
cp .build/checkouts/MSDisplayLink/LICENSE "$app_dir/Contents/Resources/Licenses/MSDisplayLink.txt"
cp .build/checkouts/swift-markdown/LICENSE.txt "$app_dir/Contents/Resources/Licenses/SwiftMarkdown.txt"
cp .build/checkouts/SwiftMath/LICENSE "$app_dir/Contents/Resources/Licenses/SwiftMath.txt"
cp Resources/Mermaid/LICENSE "$app_dir/Contents/Resources/Licenses/Mermaid.txt"
cp .build/checkouts/swift-cmark/COPYING "$app_dir/Contents/Resources/Licenses/SwiftCMark.txt"
cp THIRD_PARTY.md "$app_dir/Contents/Resources/Licenses/THIRD_PARTY.md"
cp LICENSE "$app_dir/Contents/Resources/Licenses/Perch.txt"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
