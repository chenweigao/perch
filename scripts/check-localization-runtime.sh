#!/bin/bash
# Isolated app bundle: never reads/writes Perch's preferences or connects agents.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/.local/LocalizationChecks.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -R Resources/Localization/*.lproj "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.perch.localization-checks</string>
<key>CFBundleExecutable</key><string>LocalizationChecks</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
</dict></plist>
PLIST
swiftc -swift-version 5 Sources/WorkbenchCore/Localization.swift Tests/LocalizationChecks/main.swift -o "$app/Contents/MacOS/LocalizationChecks"
"$app/Contents/MacOS/LocalizationChecks"
