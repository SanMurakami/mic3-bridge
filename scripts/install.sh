#!/bin/bash
# システム導入専用。管理者認証後に実行する。
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$EUID" -ne 0 ]]; then
    echo '管理者権限が必要です。Install.command を使用してください。' >&2
    exit 1
fi
install_mode="${1:-}"
if [[ -n "$install_mode" && "$install_mode" != '--app-only' ]]; then exit 1; fi
build_dir="$repo_dir/.build"
codesign --verify --deep --strict "$build_dir/DJIMicInputs.driver"
codesign --verify --deep --strict "$build_dir/DJI Mic Bridge.app"
backup_dir="/Library/Application Support/DJI Mic Bridge/Backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir" /Library/Audio/Plug-Ins/HAL
if [[ "$install_mode" != '--app-only' && -e '/Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver' ]]; then
    ditto '/Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver' "$backup_dir/DJIMicInputs.driver"
fi
if [[ -e '/Applications/DJI Mic Bridge.app' ]]; then
    ditto '/Applications/DJI Mic Bridge.app' "$backup_dir/DJI Mic Bridge.app"
fi
if [[ "$install_mode" != '--app-only' ]]; then ditto "$build_dir/DJIMicInputs.driver" '/Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver'; fi
ditto "$build_dir/DJI Mic Bridge.app" '/Applications/DJI Mic Bridge.app'
chown -R root:wheel '/Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver' '/Applications/DJI Mic Bridge.app'
# この再起動で他の音声アプリの接続も一時的に切れる。Install.command にも表示する。
if [[ "$install_mode" != '--app-only' ]]; then killall -TERM coreaudiod || true; fi
echo 'ドライバーとアプリを導入しました。'
