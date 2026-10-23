#!/bin/bash
set -euo pipefail
launchctl bootout "gui/$(id -u)/local.dji-mic.bridge" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.dji-mic.bridge.plist"
echo '常駐を停止しました。仮想入力は残り、無音になります。'
