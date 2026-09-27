#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/dist/MKV Legenda.app"

cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/ModuleCache"
swift build --disable-sandbox -c release --scratch-path "$project_dir/.build"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp ".build/release/MKVLegenda" "$app_dir/Contents/MacOS/MKVLegenda"
cp "Info.plist" "$app_dir/Contents/Info.plist"
cp "Sources/MKVLegenda/Resources/lesc-logo.png" "$app_dir/Contents/Resources/lesc-logo.png"
xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"

echo "$app_dir"
