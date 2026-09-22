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
app_dir="$PWD/build/Perch.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/AgentWorkbench" "$app_dir/Contents/MacOS/AgentWorkbench"
for bundle in "$bin_dir"/*.bundle; do
    cp -R "$bundle" "$app_dir/Contents/Resources/"
done
cp -R "$PWD/Resources/Localization/"*.lproj "$app_dir/Contents/Resources/"
cp Resources/Brand/Perch.icns "$app_dir/Contents/Resources/Perch.icns"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources/RemoteSetup/scripts" "$app_dir/Contents/Resources/RemoteSetup/remote"
cp scripts/install-native-service.sh "$app_dir/Contents/Resources/RemoteSetup/scripts/"
cp remote/native-agent-service.py remote/qoder-worker.mjs remote/package.json "$app_dir/Contents/Resources/RemoteSetup/remote/"

mkdir -p "$app_dir/Contents/Resources/Licenses"
cp .build/checkouts/libghostty-spm/LICENSE "$app_dir/Contents/Resources/Licenses/GhosttyKit.txt"
cp .build/checkouts/MSDisplayLink/LICENSE "$app_dir/Contents/Resources/Licenses/MSDisplayLink.txt"
cp .build/checkouts/swift-markdown/LICENSE.txt "$app_dir/Contents/Resources/Licenses/SwiftMarkdown.txt"
cp .build/checkouts/swift-cmark/COPYING "$app_dir/Contents/Resources/Licenses/SwiftCMark.txt"
cp THIRD_PARTY.md "$app_dir/Contents/Resources/Licenses/THIRD_PARTY.md"
cp LICENSE "$app_dir/Contents/Resources/Licenses/Perch.txt"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
