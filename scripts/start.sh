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
launchctl bootstrap "gui/$(id -u)" "$agent_dir/local.dji-mic.bridge.plist"
echo "常駐を開始しました。ログ: $log_dir/bridge.log"
