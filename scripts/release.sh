#!/bin/bash
# One-command release: bump → gates → confirm → tag → push. The release
# workflow publishes the zip a few minutes after the tag lands.
#
#   scripts/release.sh <patch|minor|major> [--yes]
#   scripts/release.sh patch --dry-run   # run every gate, change nothing
set -euo pipefail
cd "$(dirname "$0")/.."

bump=""
dry=0
assume_yes=0
for arg in "$@"; do
    case "$arg" in
        patch|minor|major) bump="$arg" ;;
        --dry-run) dry=1 ;;
        --yes) assume_yes=1 ;;
        *) echo "usage: scripts/release.sh <patch|minor|major> [--dry-run] [--yes]" >&2; exit 2 ;;
    esac
done
[ -n "$bump" ] || { echo "usage: scripts/release.sh <patch|minor|major> [--dry-run] [--yes]" >&2; exit 2; }

# Release only from a clean, in-sync main.
[ "$(git branch --show-current)" = "main" ] || { echo "release.sh runs on main" >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "working tree must be clean" >&2; exit 1; }
git fetch origin main --quiet
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not in sync with origin" >&2; exit 1; }

plist=Resources/Info.plist
current="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$plist")"
IFS=. read -r major minor patch <<< "$current"
case "$bump" in
    major) major=$((major+1)); minor=0; patch=0 ;;
    minor) minor=$((minor+1)); patch=0 ;;
    patch) patch=$((patch+1)) ;;
esac
next="$major.$minor.$patch"
echo "版本: $current → $next"

if [ "$dry" = 1 ]; then
    echo "[dry-run] 不写版本、不提交、不打 tag；只跑门禁。"
else
    python3 - "$plist" "$current" "$next" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
needle = f"<key>CFBundleShortVersionString</key><string>{old}</string>"
assert text.count(needle) == 1, "version key not found or ambiguous"
open(path, "w").write(text.replace(needle, f"<key>CFBundleShortVersionString</key><string>{new}</string>"))
PY
fi

# Gates: the release commit must carry the same evidence as a normal change.
./scripts/build.sh
swift run WorkbenchChecks
swift run ConnectionChecks
python3 scripts/check-localization.py
python3 scripts/check-public-source.py
python3 -m unittest discover -s Tests/Publication -q

if [ "$dry" = 1 ]; then
    echo "[dry-run] 门禁全过。实跑将提交版本、打 v$next 并推送。"
    exit 0
fi

git add "$plist"
git commit -m "chore: 版本 $next"

echo ""
# Brace the version: macOS bash 3.2 otherwise reads the multibyte character
# after $next as part of the variable name (next<bytes>: unbound variable).
echo "即将发布 v${next}（commit $(git rev-parse --short HEAD)）。发布会推送到 GitHub 并触发自动构建。"
if [ "$assume_yes" != 1 ]; then
    printf "继续？[y/N] "
    read -r answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "已取消；版本提交保留在本地（git reset --hard HEAD~1 可撤）。"; exit 1; }
fi

git tag "v$next"
python3 scripts/check-version.py
git push origin main "v$next"
echo "已推送 main 与 v$next。关注发布：gh run watch --workflow=release"
