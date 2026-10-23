#!/usr/bin/env bash
set -euo pipefail

# X向けWXT拡張機能専用のログイン済みChrome。通常のChromeプロファイルとは分離する。
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "このスクリプトはmacOS専用です。" >&2
  exit 1
fi

chrome_app="/Applications/Google Chrome.app"
profile="${HOME}/.wxt-shared-chrome"
if [[ ! -d "$chrome_app" ]]; then
  echo "Google Chromeが見つかりません: $chrome_app" >&2
  exit 1
fi

mkdir -p "$profile"
chmod 700 "$profile"

# 既にこのプロファイルが開いていればChrome側の既存プロセスへ引き継がれる。
open -na "$chrome_app" --args \
  "--user-data-dir=$profile" \
  --no-first-run --no-default-browser-check \
  "https://x.com/home"

echo "X向けWXT共通プロファイル: $profile"
echo "拡張機能の追加: chrome://extensions/ → デベロッパーモード → パッケージ化されていない拡張機能を読み込む"
