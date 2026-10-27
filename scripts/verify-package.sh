#!/bin/bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
package="${1:?検証するpkgのパスを指定してください。}"
work_dir="$(mktemp -d "$repo_dir/.build/package-check.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
pkgutil --expand-full "$package" "$work_dir/expanded"
payload="$work_dir/expanded/Mic3Bridge-component.pkg/Payload"
app="$payload/Applications/DJI Mic Bridge.app"
driver="$payload/Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver"
codesign --verify --deep --strict "$app"
codesign --verify --deep --strict "$driver"
python3 - "$payload" "$repo_dir" <<'PY'
import pathlib, plistlib, sys
root, repo = map(pathlib.Path, sys.argv[1:])
app = root / 'Applications/DJI Mic Bridge.app/Contents'
driver = root / 'Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver/Contents'
for bundle, info in [(app, 'Bridge-Info.plist'), (driver, 'Driver-Info.plist')]:
    assert plistlib.loads((bundle / 'Info.plist').read_bytes()) == plistlib.loads((repo / 'packaging' / info).read_bytes())
    assert (bundle / 'Resources/LICENSE.txt').read_bytes() == (repo / 'LICENSE').read_bytes()
    assert not any(path.is_symlink() for path in bundle.rglob('*'))
expected = {
    'Applications/DJI Mic Bridge.app/Contents/Info.plist',
    'Applications/DJI Mic Bridge.app/Contents/_CodeSignature/CodeResources',
    'Applications/DJI Mic Bridge.app/Contents/MacOS/DJIMicBridge',
    'Applications/DJI Mic Bridge.app/Contents/MacOS/dji-mic-bridge',
    'Applications/DJI Mic Bridge.app/Contents/MacOS/dji-mic-control',
    'Applications/DJI Mic Bridge.app/Contents/Resources/AppIcon.icns',
    'Applications/DJI Mic Bridge.app/Contents/Resources/LICENSE.txt',
    'Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver/Contents/Info.plist',
    'Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver/Contents/_CodeSignature/CodeResources',
    'Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver/Contents/MacOS/DJIMicInputs',
    'Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver/Contents/Resources/LICENSE.txt',
    'Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver/Contents/Resources/Apple-LICENSE.txt',
}
actual = {str(path.relative_to(root)) for path in root.rglob('*') if path.is_file()}
assert actual == expected, f'Unexpected payload: {actual ^ expected}'
PY
for binary in "$app/Contents/MacOS/"* "$driver/Contents/MacOS/"*; do
    for arch in arm64 x86_64; do
        xcrun lipo "$binary" -verify_arch "$arch"
        xcrun vtool -arch "$arch" -show-build "$binary" | awk '
            $1 == "minos" { found = 1; if ($2 != "14.0") exit 1 }
            END { if (!found) exit 1 }'
    done
    if otool -L "$binary" | grep -E '^[[:space:]]+(/Users/|/opt/|/usr/local/|@rpath/)' ; then
        echo "標準環境にないライブラリへの依存があります: $binary" >&2; exit 1
    fi
done
echo 'パッケージの内容・署名・両アーキテクチャ・macOS最小バージョンを確認しました。'
