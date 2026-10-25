#!/usr/bin/env bash
set -euo pipefail

# X向けWXT拡張機能専用。WXT/web-extにブラウザを起動させない。
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS専用です。" >&2
  exit 1
fi

chrome_app="/Applications/Google Chrome.app"
profile="${HOME}/.wxt-shared-chrome"
port=9341
if [[ ! -d "$chrome_app" ]]; then
  echo "Google Chromeが見つかりません: $chrome_app" >&2
  exit 1
fi

mkdir -p "$profile"
chmod 700 "$profile"

# 既存のログイン用Chromeを保護する。起動中は絶対に2つ目を開かない。
lock="$profile/SingletonLock"
if [[ -L "$lock" ]]; then
  owner="$(readlink "$lock")"
  pid="${owner##*-}"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "X専用Chromeは既に起動中です (PID: $pid)。"
    echo "デバッグポートが無効な場合は、Chromeを通常終了してから再起動してください。"
    exit 0
  fi
fi

# ほかのChromeがデバッグポートを使用していたら誤接続を避ける。
if /usr/sbin/lsof -nP -t -iTCP:${port} -sTCP:LISTEN 2>/dev/null | grep -q .; then
  echo "ポート${port}は別のプロセスが使用中です。X専用Chromeは起動しません。" >&2
  exit 1
fi

open -na "$chrome_app" --args \
  "--user-data-dir=$profile" \
  "--remote-debugging-address=127.0.0.1" \
  "--remote-debugging-port=$port" \
  --no-first-run --no-default-browser-check \
  "https://x.com/home"

echo "X向けWXT共通プロファイル: $profile"
echo "拡張機能の開発: 各プロジェクトで pnpm dev:shared"
