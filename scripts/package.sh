#!/bin/bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
    '') bash "$repo_dir/scripts/build.sh" --universal ;;
    --skip-build) ;;
    *) echo '使用方法: package.sh [--skip-build]' >&2; exit 1 ;;
esac
build_dir="$repo_dir/.build"
package_dir="$build_dir/package"
release_dir="$build_dir/release"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_dir/packaging/Bridge-Info.plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo 'バージョン番号が不正です。' >&2; exit 1; fi
if [[ "${GITHUB_REF_TYPE:-}" == tag && "${GITHUB_REF_NAME:-}" != "v$version" ]]; then
    echo 'タグとアプリのバージョンが一致していません。' >&2; exit 1
fi
for bundle in 'DJI Mic Bridge.app' DJIMicInputs.driver; do
    codesign --verify --deep --strict "$build_dir/$bundle"
    for binary in "$build_dir/$bundle/Contents/MacOS/"*; do
        for arch in arm64 x86_64; do xcrun lipo "$binary" -verify_arch "$arch"; done
    done
done
rm -rf "$package_dir" "$release_dir"
mkdir -p "$package_dir/root/Applications" "$package_dir/root/Library/Audio/Plug-Ins/HAL" "$release_dir"
ditto --norsrc --noextattr "$build_dir/DJI Mic Bridge.app" "$package_dir/root/Applications/DJI Mic Bridge.app"
ditto --norsrc --noextattr "$build_dir/DJIMicInputs.driver" "$package_dir/root/Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver"
pkgbuild --root "$package_dir/root" --identifier local.dji-mic.bridge.installer \
    --version "$version" --install-location / --ownership recommended \
    --component-plist "$repo_dir/packaging/Components.plist" --scripts "$repo_dir/packaging/scripts" \
    "$package_dir/Mic3Bridge-component.pkg"
filename="Mic3Bridge-$version-universal.pkg"
productbuild --distribution "$repo_dir/packaging/Distribution.xml" \
    --resources "$repo_dir/packaging/resources" --package-path "$package_dir" "$release_dir/$filename"
(cd "$release_dir" && shasum -a 256 "$filename" > SHA256SUMS.txt)
printf 'インストーラー: %s\n' "$release_dir/$filename"
