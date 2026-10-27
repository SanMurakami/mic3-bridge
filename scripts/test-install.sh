#!/bin/bash
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted ]]; then
    echo 'このテストはGitHub hosted runner専用です。' >&2; exit 1
fi
package="${1:?テストするpkgのパスを指定してください。}"
app='/Applications/DJI Mic Bridge.app'
driver='/Library/Audio/Plug-Ins/HAL/DJIMicInputs.driver'
work_dir="$(mktemp -d "$RUNNER_TEMP/mic3-install.XXXXXX")"
helper_pid=''
cleanup() {
    if [[ -n "$helper_pid" ]]; then kill "$helper_pid" 2>/dev/null || true; wait "$helper_pid" 2>/dev/null || true; fi
    rm -rf "$work_dir"
}
trap cleanup EXIT
sudo installer -pkg "$package" -target /
codesign --verify --deep --strict "$app"
codesign --verify --deep --strict "$driver"
[[ "$(stat -f '%Su:%Sg' "$app")" == root:wheel ]]
[[ "$(stat -f '%Su:%Sg' "$driver")" == root:wheel ]]
"$app/Contents/MacOS/dji-mic-bridge" --seconds 120 --config "$work_dir/receivers.json" > "$work_dir/snapshots.jsonl" &
helper_pid=$!
ready=false
for attempt in {1..60}; do
    if jq -se 'length > 0 and (last | .error == "" and .bus_channels == 16)' "$work_dir/snapshots.jsonl" >/dev/null; then
        ready=true; break
    fi
    kill -0 "$helper_pid"
    sleep 0.5
done
if [[ "$ready" != true ]]; then cat "$work_dir/snapshots.jsonl"; exit 1; fi
system_profiler SPAudioDataType -json > "$work_dir/audio.json"
jq -e '[.. | objects | select(._name? == "DJI Mic3 Matrix")] | length > 0' "$work_dir/audio.json"
# 使用中の更新を拒否し、起動中のプロセスを終了させない。
if sudo installer -pkg "$package" -target / > "$work_dir/active-install.log" 2>&1; then
    echo '起動中のインストールが拒否されませんでした。' >&2; exit 1
fi
kill -0 "$helper_pid"
kill "$helper_pid"
wait "$helper_pid"
helper_pid=''
shasum -a 256 "$work_dir/receivers.json" "$work_dir/routing.json" > "$work_dir/config.sha256"
# 更新時に古いbundleの不要ファイルを残さず、ユーザー設定は保持する。
sudo touch "$app/Contents/Resources/obsolete-install-test.txt"
sudo installer -pkg "$package" -target /
[[ ! -e "$app/Contents/Resources/obsolete-install-test.txt" ]]
shasum -a 256 -c "$work_dir/config.sha256"
codesign --verify --deep --strict "$app"
codesign --verify --deep --strict "$driver"
"$app/Contents/MacOS/dji-mic-bridge" --seconds 5 --config "$work_dir/receivers.json" > "$work_dir/updated.jsonl"
jq -se 'length > 0 and (last | .error == "" and .bus_channels == 16)' "$work_dir/updated.jsonl"
echo '新規導入・HAL認識・起動中の更新拒否・再インストールを確認しました。'
