#!/bin/bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_dir/.build"
architectures=("$(uname -m)")
case "${1:-}" in
    --universal) architectures=(arm64 x86_64) ;;
    '') ;;
    *) echo '使用方法: build.sh [--universal]' >&2; exit 1 ;;
esac
sdk="$(xcrun --sdk macosx --show-sdk-path)"
minimum_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$repo_dir/packaging/Bridge-Info.plist")
driver_dir="$build_dir/DJIMicInputs.driver/Contents"
app_dir="$build_dir/DJI Mic Bridge.app/Contents"
rm -rf -- "$build_dir/DJI Mic Bridge.app" "$build_dir/DJIMicInputs.driver"
mkdir -p "$driver_dir/MacOS" "$driver_dir/Resources" "$app_dir/MacOS" "$app_dir/Resources"
for arch in "${architectures[@]}"; do
    arch_dir="$build_dir/architectures/$arch"
    mkdir -p "$arch_dir"
    target="$arch-apple-macos$minimum_os"
    xcrun clang -target "$target" -isysroot "$sdk" -std=c11 -O2 -Wall -Wextra -Werror -fblocks -fvisibility=hidden -bundle \
        -framework CoreAudio -framework CoreFoundation \
        "$repo_dir/driver/Driver.c" -o "$arch_dir/DJIMicInputs"
    xcrun clang++ -target "$target" -isysroot "$sdk" -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Werror \
        -framework CoreAudio -framework CoreFoundation -framework Foundation -framework AVFoundation -framework IOKit -framework IOUSBHost -framework AudioToolbox \
        "$repo_dir/bridge/Bridge.mm" -o "$arch_dir/dji-mic-bridge" \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$repo_dir/packaging/Bridge-Info.plist"
    xcrun clang++ -target "$target" -isysroot "$sdk" -std=c++17 -O2 -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework IOKit -framework IOUSBHost \
        "$repo_dir/bridge/MicControl.mm" -o "$arch_dir/dji-mic-control"
    xcrun swiftc -target "$target" -sdk "$sdk" -O -parse-as-library -warnings-as-errors -framework SwiftUI -framework AppKit -framework AVFoundation \
        "$repo_dir/app/"*.swift -o "$arch_dir/DJIMicBridge"
done
for executable in DJIMicInputs dji-mic-bridge dji-mic-control DJIMicBridge; do
    inputs=()
    for arch in "${architectures[@]}"; do inputs+=("$build_dir/architectures/$arch/$executable"); done
    destination="$app_dir/MacOS/$executable"
    if [[ "$executable" == DJIMicInputs ]]; then destination="$driver_dir/MacOS/$executable"; fi
    xcrun lipo -create "${inputs[@]}" -output "$destination"
done
cp "$repo_dir/packaging/Driver-Info.plist" "$driver_dir/Info.plist"
cp "$repo_dir/vendor/apple-null-audio/LICENSE.txt" "$driver_dir/Resources/Apple-LICENSE.txt"
cp "$repo_dir/LICENSE" "$driver_dir/Resources/LICENSE.txt"
cp "$repo_dir/LICENSE" "$app_dir/Resources/LICENSE.txt"
cp "$repo_dir/packaging/Bridge-Info.plist" "$app_dir/Info.plist"
cp "$repo_dir/assets/AppIcon.icns" "$app_dir/Resources/AppIcon.icns"
codesign --force --sign - "$build_dir/DJIMicInputs.driver"
codesign --force --sign - "$app_dir/MacOS/dji-mic-bridge"
codesign --force --sign - "$app_dir/MacOS/dji-mic-control"
codesign --force --sign - "$build_dir/DJI Mic Bridge.app"
printf 'ビルド完了: %s\n' "$build_dir"
