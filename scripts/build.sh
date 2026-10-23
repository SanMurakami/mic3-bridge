#!/bin/bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_dir/.build"
driver_dir="$build_dir/DJIMicInputs.driver/Contents"
app_dir="$build_dir/DJI Mic Bridge.app/Contents"
rm -rf -- "$build_dir/DJI Mic Bridge.app" "$build_dir/DJIMicInputs.driver"
mkdir -p "$driver_dir/MacOS" "$driver_dir/Resources" "$app_dir/MacOS" "$app_dir/Resources"
clang -std=c11 -O2 -Wall -Wextra -Werror -fblocks -fvisibility=hidden -bundle \
    -framework CoreAudio -framework CoreFoundation \
    "$repo_dir/driver/Driver.c" -o "$driver_dir/MacOS/DJIMicInputs"
cp "$repo_dir/packaging/Driver-Info.plist" "$driver_dir/Info.plist"
cp "$repo_dir/vendor/apple-null-audio/LICENSE.txt" "$driver_dir/Resources/Apple-LICENSE.txt"
clang++ -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Werror \
    -framework CoreAudio -framework CoreFoundation -framework Foundation -framework AVFoundation -framework IOKit \
    "$repo_dir/bridge/Bridge.mm" -o "$app_dir/MacOS/dji-mic-bridge" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$repo_dir/packaging/Bridge-Info.plist"
cp "$repo_dir/packaging/Bridge-Info.plist" "$app_dir/Info.plist"
codesign --force --sign - "$build_dir/DJIMicInputs.driver"
codesign --force --sign - "$build_dir/DJI Mic Bridge.app"
printf 'ビルド完了: %s\n' "$build_dir"
