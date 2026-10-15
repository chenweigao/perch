#!/bin/bash
# Release artifact: release build → ad-hoc signature → zipped app + checksum.
# No Apple Developer identity is involved; Gatekeeper asks for a right-click
# open on first launch (see docs/RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)"
revision="$(git describe --tags --dirty --always 2>/dev/null || echo unknown)"
out_dir="$PWD/build/release"
rm -rf "$out_dir"
mkdir -p "$out_dir"

WORKBENCH_APP_DIR="$out_dir/Perch.app" ./scripts/build.sh

app="$out_dir/Perch.app"
codesign --verify --deep --strict "$app"

zip_name="Perch-$version-$revision.zip"
ditto -c -k --keepParent "$app" "$out_dir/$zip_name"
shasum -a 256 "$out_dir/$zip_name" > "$out_dir/$zip_name.sha256"

echo "$out_dir/$zip_name"
