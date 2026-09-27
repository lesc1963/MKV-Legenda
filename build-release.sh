#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_path="$project_dir/dist/MKV Legenda.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")"
archive_path="$project_dir/dist/MKV-Legenda-${version}-arm64.zip"
staging_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/mkv-legenda-release.XXXXXX")"
staged_app="$staging_dir/MKV Legenda.app"
trap 'rm -rf "$staging_dir"' EXIT

zsh "$project_dir/build-app.sh"
ditto --norsrc "$app_path" "$staged_app"
xattr -cr "$staged_app"
codesign --force --deep --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"
COPYFILE_DISABLE=1 ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$archive_path"

echo "$archive_path"
