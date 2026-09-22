#!/bin/bash
# Full production workbench with a compile-time-only, offline fixture entrypoint.
set -euo pipefail
cd "$(dirname "$0")/.."
swift package resolve
checkout="$PWD/.build/checkouts/libghostty-spm"
patch_file="$PWD/patches/ghostty-app-resources.patch"
if ! git -C "$checkout" apply --reverse --check "$patch_file" 2>/dev/null; then
    git -C "$checkout" apply --check "$patch_file"
    git -C "$checkout" apply "$patch_file"
fi
swift build --build-system native -c release --product AgentWorkbench \
    -Xswiftc -DPERCH_ACCEPTANCE -Xswiftc -DTRANSCRIPT_CHECKS
bin_dir="$(swift build --build-system native -c release --show-bin-path)"
app_dir="$PWD/build/Perch Acceptance.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/AgentWorkbench" "$app_dir/Contents/MacOS/NativeAcceptance"
for bundle in "$bin_dir"/*.bundle; do cp -R "$bundle" "$app_dir/Contents/Resources/"; done
cp -R Resources/Localization/*.lproj "$app_dir/Contents/Resources/"
python3 - "$app_dir" <<'PY'
import hashlib, json, pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes())
info.update(CFBundleIdentifier='dev.perch.nativeacceptance', CFBundleName='Perch Acceptance',
            CFBundleDisplayName='Perch Acceptance', CFBundleExecutable='NativeAcceptance')
info.pop('CFBundleIconFile', None)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
digest = hashlib.sha256()
for path in sorted(pathlib.Path('Sources').rglob('*.swift')) + [pathlib.Path('Package.resolved')]:
    digest.update(str(path).encode()); digest.update(path.read_bytes())
metadata = {'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'source_sha256': digest.hexdigest(), 'configuration': 'release -O',
            'defines': ['PERCH_ACCEPTANCE', 'TRANSCRIPT_CHECKS'],
            'compiler': subprocess.check_output(['swift', '--version'], text=True).strip(),
            'window_points': [1280, 820], 'history_turns': 200, 'catalog_sessions': 500,
            'resident_snapshot_count': 8}
(app / 'Contents/Resources/build.json').write_text(json.dumps(metadata, indent=2))
PY
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
echo "$app_dir"
