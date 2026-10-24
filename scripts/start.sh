#!/bin/bash
set -euo pipefail
app_path='/Applications/DJI Mic Bridge.app'
app_executable="$app_path/Contents/MacOS/DJIMicBridge"
if [[ ! -x "$app_executable" ]]; then echo '先に Install.command で導入してください。' >&2; exit 1; fi
agent_dir="$HOME/Library/LaunchAgents"
log_dir="$HOME/Library/Logs/DJI Mic Bridge"
mkdir -p "$agent_dir" "$log_dir"
# plist を文字列連結せず、パスを正確に保存する。
/usr/bin/python3 - "$app_executable" "$log_dir" "$agent_dir/local.dji-mic.bridge.plist" <<'PY'
import plistlib,sys
executable,logs,destination=sys.argv[1:]
with open(destination,'wb') as f:
    plistlib.dump({'Label':'local.dji-mic.bridge','ProgramArguments':[executable],
      'RunAtLoad':True,'KeepAlive':{'SuccessfulExit':False},'ThrottleInterval':5,
      'StandardOutPath':logs+'/bridge.log','StandardErrorPath':logs+'/bridge.log'},f)
PY
launchctl bootout "gui/$(id -u)/local.dji-mic.bridge" 2>/dev/null || true
# bootout の返却直後は launchd が旧サービスを削除中の場合がある。
started=false
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$(id -u)" "$agent_dir/local.dji-mic.bridge.plist"; then started=true; break; fi
    sleep 0.5
done
if [[ "$started" != true ]]; then echo '常駐の登録に失敗しました。' >&2; exit 1; fi
echo "常駐を開始しました。ログ: $log_dir/bridge.log"
