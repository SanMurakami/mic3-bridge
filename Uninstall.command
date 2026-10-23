#!/bin/bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$repo_dir/scripts/stop.sh"
/usr/bin/osascript <<'APPLESCRIPT'
do shell script "/bin/rm -rf '/Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver' '/Applications/DJI Mic Bridge.app'; /usr/bin/killall -TERM coreaudiod || true" with administrator privileges
APPLESCRIPT
echo '専用ドライバーとアプリを削除しました。設定とログはユーザーの Library に残しています。'
