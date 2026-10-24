#!/bin/bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
install_mode="${1:-}"
if [[ -n "$install_mode" && "$install_mode" != '--app-only' ]]; then echo '引数: --app-only または引数なし' >&2; exit 1; fi
echo 'DJI Mic Inputs を導入します。'
if [[ "$install_mode" == '--app-only' ]]; then
    echo 'アプリのみ更新します。Core Audio は再起動しません。'
else
    echo 'macOS の管理者認証が必要です。Core Audio の再起動で、他の音声アプリも一時的に切断されます。'
fi
"$repo_dir/scripts/build.sh"
# 管理者側の osascript は Documents を読めない場合があるため、導入物だけを保護された一時フォルダーへ移す。
install_stage="$(mktemp -d /private/tmp/dji-mic-install.XXXXXX)"
trap 'rm -rf -- "$install_stage"' EXIT
mkdir -p "$install_stage/scripts" "$install_stage/.build"
cp "$repo_dir/scripts/install.sh" "$install_stage/scripts/install.sh"
ditto "$repo_dir/.build/DJIMicInputs.driver" "$install_stage/.build/DJIMicInputs.driver"
ditto "$repo_dir/.build/DJI Mic Bridge.app" "$install_stage/.build/DJI Mic Bridge.app"
/usr/bin/osascript - "$install_stage/scripts/install.sh" "$install_mode" <<'APPLESCRIPT'
on run argv
    do shell script "/bin/bash " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) with administrator privileges
end run
APPLESCRIPT
"$repo_dir/scripts/start.sh"
echo '導入しました。必要ならマイク利用を許可してください。'
