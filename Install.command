#!/bin/bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
echo 'DJI Mic Inputs を導入します。'
echo 'macOS の管理者認証が必要です。Core Audio の再起動で、他の音声アプリも一時的に切断されます。'
"$repo_dir/scripts/build.sh"
/usr/bin/osascript - "$repo_dir/scripts/install.sh" <<'APPLESCRIPT'
on run argv
    do shell script "/bin/bash " & quoted form of (item 1 of argv) with administrator privileges
end run
APPLESCRIPT
"$repo_dir/scripts/start.sh"
echo '導入しました。必要ならマイク利用を許可してください。'
