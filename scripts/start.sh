#!/bin/bash
set -euo pipefail
app_path='/Applications/DJI Mic Bridge.app'
app_executable="$app_path/Contents/MacOS/DJIMicBridge"
if [[ ! -x "$app_executable" ]]; then echo '先に Install.command で導入してください。' >&2; exit 1; fi
# launchd管理外から開いた旧GUIも対象にする。Mac収録中の再起動は拒否する。
bridge_executable="$app_path/Contents/MacOS/dji-mic-bridge"
startup_uid="$(id -u)"
existing_gui=""; existing_helpers=""
while IFS= read -r pid; do
    [[ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" == "$app_executable" ]] && existing_gui+=" $pid"
done < <(pgrep -u "$startup_uid" -f '^/Applications/DJI Mic Bridge.app/Contents/MacOS/DJIMicBridge$' || true)
while IFS= read -r pid; do
    if [[ "$(ps -p "$pid" -o comm= 2>/dev/null || true)" == "$bridge_executable" ]]; then
        existing_helpers+=" $pid"
        while IFS= read -r open_file; do
            case "$open_file" in
                n*.caf|n*.caf' (deleted)')
                    echo 'Mac収録中のため再起動していません。収録終了後に scripts/start.sh を実行してください。' >&2
                    exit 1 ;;
            esac
        done < <(lsof -a -p "$pid" -Fn 2>/dev/null || true)
    fi
done < <(pgrep -u "$startup_uid" -f '^/Applications/DJI Mic Bridge.app/Contents/MacOS/dji-mic-bridge$' || true)
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
for pid in $existing_gui; do kill -TERM "$pid" 2>/dev/null || true; done
# 親GUI終了後にhelperがファイルとUSB操作を閉じるまで待ち、二重起動を防ぐ。
old_stopped=false
for attempt in {1..100}; do
    old_stopped=true
    for pid in $existing_gui $existing_helpers; do
        if kill -0 "$pid" 2>/dev/null; then old_stopped=false; fi
    done
    if [[ "$old_stopped" == true ]]; then break; fi
    sleep 0.1
done
if [[ "$old_stopped" != true ]]; then echo '旧プロセスの終了を待っています。終了後に scripts/start.sh を再実行してください。' >&2; exit 1; fi
# bootout の返却直後は launchd が旧サービスを削除中の場合がある。
started=false
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$(id -u)" "$agent_dir/local.dji-mic.bridge.plist"; then started=true; break; fi
    sleep 0.5
done
if [[ "$started" != true ]]; then echo '常駐の登録に失敗しました。' >&2; exit 1; fi
echo "常駐を開始しました。ログ: $log_dir/bridge.log"
