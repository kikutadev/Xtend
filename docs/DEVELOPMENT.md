# 開発者向けビルド・インストール手順

XtendはiOS 18以降向けのiPhoneアプリです。ここでは、開発・検証用のビルド方法と拡張機能のZIP作成方法を説明します。一般利用者向けの説明は[README](../README.md)を参照してください。

## 前提条件

- macOS、iOS 18以降に対応するXcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen)
- 実機向けの場合は、Xcodeに登録済みのApple ID・署名用Team、接続・信頼済みのiPhone（開発者モード有効）
- リポジトリ直下を作業ディレクトリとする

```sh
brew install xcodegen  # 未インストールの場合
xcodegen generate
```

## iPhone実機へのビルドとインストール

[READMEの実機向けコマンド](../README.md#iphoneへのインストール)でTeam ID・端末IDを指定して実行できます。Xcodeで直接実行したい場合は次の手順です。

1. `open Xtend.xcodeproj` で開き、`Xtend` ターゲットの **Signing & Capabilities** で自分のTeamを指定します。
2. **Bundle Identifier** を `org.example.xtend` から自分固有のIDに変更します。
3. iPhoneを選択し、`Xtend` スキームの **Run** を実行します。

`xcodegen generate` の再実行によって、Xcode上で手動変更した署名設定が戻る場合があります。繰り返し使う場合はREADMEのようにビルド時の引数でTeamとBundle IDを渡してください。

## Simulatorビルド（開発・検証用）

Simulatorは実機へのインストールには使いません。署名も不要です。

```sh
xcodegen generate
xcodebuild -project Xtend.xcodeproj -scheme Xtend \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

ビルド成果物は `.build/DerivedData/Build/Products/Debug-iphonesimulator/Xtend.app` です。起動済みのSimulatorにインストールする場合は次を実行します。

```sh
xcrun simctl install booted .build/DerivedData/Build/Products/Debug-iphonesimulator/Xtend.app
xcrun simctl launch booted org.example.xtend
```

Releaseビルドは `-configuration Release` に変更します。生成先は `.build/DerivedData/Build/Products/Release-iphonesimulator/Xtend.app` です。いずれもSimulator専用で、iPhone実機にインストールできません。

## 自動テスト（Phase 2）

`xcodegen generate`後、`xcrun simctl list devices available`でSimulatorのIDを確認して実行します。

```sh
xcodebuild -project Xtend.xcodeproj -scheme Xtend \
  -configuration Debug -destination 'platform=iOS Simulator,id=<SimulatorのUUID>' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

合成fixtureでZIPの不正パスとシンボリックリンク、破損パッケージの隔離、保存値の分離・変更通知、更新中断からの復旧を検証します。共通の `ExtensionStorageTests` は、`local` / `sync` のファイル保存・復元、拡張機能間の分離、旧 `UserDefaults` の引継ぎ、保存エラー時の通知抑止を検証します。`test01WriteSharedStorageBeforeRestart` と `test02ReadSharedStorageAfterRestart` を別々の `xcodebuild test` 呼び出しで連続実行すると、テストホスト終了後の復元を検証できます。`XtendUITests`は既存のSimulator上でブラウザーが開ける場合に、設定画面の往復と手動再読み込みのUI操作を検証します。初回案内画面のままなら該当UIテストはスキップします。

Mac上でSimulatorのGUIを開かずに実行する場合は、既存のSimulatorを`xcrun simctl boot <SimulatorのUUID>`（未起動時のみ）と`xcrun simctl bootstatus <SimulatorのUUID> -b`で起動し、上記の`xcodebuild`を実行します。UIテストが起動するXtendのデータコンテナは変わる場合があるため、手動で外部ファイルをアプリコンテナへ置いておく方式をテストの前提にしないでください。Xのログイン状態やWebサイトのデータはリポジトリに保存しません。

### ログイン済みSimulatorでx-home-anchorを再配置する

配布用ZIPをアプリに同梱せず、ローカルの `.build/x-home-anchor.zip` から、既存のXtendデータコンテナにx-home-anchorだけを配置できます。XのCookie、設定、他の拡張機能は変更しません。既にx-home-anchorがある場合も上書きしません。

```sh
scripts/seed-simulator-x-home-anchor.sh <SimulatorのUUID>  # .build/x-home-anchor.zip を使用
# ほかのZIPなら scripts/seed-simulator-x-home-anchor.sh <SimulatorのUUID> /path/to/x-home-anchor.zip
xcrun simctl terminate <SimulatorのUUID> org.example.xtend
xcrun simctl launch <SimulatorのUUID> org.example.xtend
```

このスクリプトは**拡張機能を自動削除しません**。UIテストの再インストールによりアプリデータコンテナが変わった場合は再実行できます。配布用ZIPがなくなった場合は下記の手順で再作成してください。これはXCUITestによるインストール操作の検証ではありません。

Chrome Web Storeからの実ダウンロード、拡張機能変更直後の自動再読み込み（URL継続・スクロール位置は復元しない）は別途実機またはログイン済みSimulatorで検証が必要です。

## x-home-anchorのビルド済みZIPを作る場合

一般の利用者は [x-home-anchorのGitHubリポジトリ](https://github.com/akiweb8528/x-home-anchor) のReleasesで配布されるビルド済みZIPを利用してください。ソースから作成する場合はNode.js 22.18以降を用意します。

```sh
mkdir -p .build
git clone --depth 1 https://github.com/akiweb8528/x-home-anchor.git .build/x-home-anchor-src
cd .build/x-home-anchor-src
npm ci
npm run check
cd dist
zip -r ../../x-home-anchor.zip .
```

作成される `.build/x-home-anchor.zip` をiPhoneの「ファイル」に移して、Xtendの設定画面から「ZIPから読み込む」を選びます。GitHubからダウンロードしたソースZIPはTypeScriptのままなので使えません。

## X向けWXT拡張機能の共通開発用Chrome

X向けWXT拡張機能 `../x-ad-hider/`、`../x-timeline-filter/` は `~/.wxt-shared-chrome` を共有します。

```sh
scripts/open-x-wxt-chrome.sh
cd ../x-timeline-filter
pnpm dev:shared
```

`pnpm dev:shared` はWXT開発サーバーを起動し、ChromeのCDP（localhost:9341）で拡張機能を自動読み込みします。複数プロジェクトから同時利用でき、Chromeは1つです。Cookieは各拡張機能にはコピーしません。

WXT標準のChrome自動起動は、macOSで保存済みログインCookieを使えなくする可能性があるため無効化します。通常の `pnpm dev` はビルドのみです。**共通ランチャーはChromeを自動起動せず**、CDP 9341の接続先が指定プロファイルの通常版Chromeかを検証してから拡張機能を読み込みます。起動スクリプトも既存Chromeが動作中なら二重起動しません。起動状態・プロファイル・WXT設定が不正な場合は停止します。新しいX用WXTプロジェクトも `../x-timeline-filter/scripts/dev-shared.mjs` を利用します。 開発サーバーのポートはプロジェクト名から割り当て、同時起動時の衝突を避けます。変更が必要なら `X_WXT_PORT` を指定します。

## Xtend標準スワイプの検証

スワイプ処理はアプリの Xtend/Resources/xtend-swipe.js で管理します。WXT拡張機能のZIP導入は不要です。

### Simulatorによるスワイプ検証

ログイン済みでXtendのXブラウザ画面が表示できるSimulatorに限り、`XtendUITests/XtendBrowserUITests.swift` の `testSwipeNavigationOnLoggedInX` がスワイプ操作と5枚のスクリーンショットを記録します。

```sh
xcodebuild -project Xtend.xcodeproj -scheme Xtend \\
  -destination 'platform=iOS Simulator,id=<SimulatorのUUID>' \\
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO \\
  -only-testing:XtendUITests/XtendBrowserUITests/testSwipeNavigationOnLoggedInX \\
  -resultBundlePath .build/SwipeEvidence.xcresult test

xcrun xcresulttool export attachments --path .build/SwipeEvidence.xcresult \\
  --output-path .build/SwipeEvidenceAttachments
python3 scripts/verify-swipe-evidence.py .build/SwipeEvidenceAttachments
```

画像判定はXの明るいテーマ・現在のモバイルレイアウト向けの補助検証で、固定座標に投稿の動画や操作ボタンが現れた場合はジェスチャーが意図的に無効化されることがあります。**XCTestの終了コードだけで切替成功と判断しない**こと。Simulatorでの確認は実iPhoneの性能・WKWebViewの競合を保証しません。

### 実Xページビュー速度A/B計測（DEBUG限定）

ログイン済みSimulatorのXtendで、標準タブ操作と先読みベータをそれぞれ10回往復させ、**操作開始から実際の投稿DOM切替（標準）／準備済みViewの交換（ベータ）を経て、WebKitの画面スナップショット完了まで**の所要時間をログに記録します。ユーザーの指のスワイプ検出時間は含みません。投稿本文やアカウント識別子はログに残しません。

```sh
# Debugビルドを既存Simulatorへインストール後、ログイン状態を保持して実行
xcrun simctl terminate booted org.example.xtend || true
xcrun simctl launch booted org.example.xtend --xtend-benchmark-pageview
# XTEND_PAGEVIEW_BENCH summary mode=standard ... まで確認後に終了
xcrun simctl terminate booted org.example.xtend
xcrun simctl launch booted org.example.xtend --xtend-test-beta-preload --xtend-benchmark-pageview
# XTEND_PAGEVIEW_BENCH summary mode=warm ... まで確認
xcrun simctl spawn booted log show --last 5m --style compact \
  --predicate 'process == "Xtend" AND eventMessage CONTAINS "XTEND_PAGEVIEW_BENCH"'
```

先読みの準備時間はログ中の`XTEND_BETA: preload selected`と`XTEND_BETA: standby ready`の差で確認できます。共有Simulatorで他のXCUITestが同時にアプリを入れ替えた測定は除外してください。実機の速度や、全リソースの通信完了時間とは別の指標です。計測結果はロードマップに記録しています。

### Xホームの先読みベータ

Xtendの設定画面の「ベータ機能 → タイムラインの先読み（ベータ）」で有効にできます。初期状態はオフで、オンにするとXホームのもう一方のタブを背面のWKWebViewで先読みします。両方のページがXと拡張機能を実行するためメモリ負荷が増えます。X以外の画面・メモリ警告・バックグラウンドでは第二WebViewを解放します。

DEBUGでのみ、設定を書き換えずに機能を試す起動引数を使えます。

```sh
xcrun simctl launch booted org.example.xtend --xtend-test-beta-preload
# ネイティブ入れ替えだけの確認（実タッチ操作のテストではない）
xcrun simctl launch --terminate-running-process booted org.example.xtend \
  --xtend-test-beta-preload --xtend-test-beta-swap
xcrun simctl spawn booted log show --last 1m --style compact \
  --predicate 'eventMessage CONTAINS "XTEND_BETA"'
```

ブラウザのジェスチャーとタブクリックの単体試験は`scripts/test-beta-tab-bridge.mjs`、実XのXCUITestは`testBetaTimelinePreloadOnActualX`です。実Xでは画面内のリンク・画像・動画上で開始したスワイプが意図的に無効化される場合があり、さらにインストール済みのキーボードショートカット案内が画面へ残るケースもあります。XCUITestの成功だけで体感やメモリの改善を断定しないでください。

`footprint -p <Xtend PID> -p <WebContent PID> ... --noCategories`を利用し、Xtend本体だけでなくWKWebViewの各WebContentプロセスを含めて比較します。共有Simulatorへ別作業が割り込んだ試行は結果から除外してください。

## GitHub Release ZIPのSimulator検証

Private ReleasesのZIPは、トークンをテストソース・Git・テストログへ記録せず、認証済みGitHub CLIで配布ZIPを取得する。QA用Bundle IDは org.example.xtend.githubrelease.qa 。Simulatorの同Bundle IDのアプリデータディレクトリ（xcrun simctl get_app_container booted org.example.xtend.githubrelease.qa data）の Documents/XtendGitHubReleaseQAFixtures/ に、x-ad-hider-0.1.0-chrome.zip と x-timeline-filter-0.1.0-chrome.zip を配置する。

CommunityExtensionStoreTests.testPublishedGitHubReleaseZIPsInstallAndLoadInSimulator は実配布ZIPのインストールと拡張機能ホストへの読み込みを検証する。未配置時はSkipになる。実行後、QAアプリのDocumentsからZIPを削除する。

GitHubReleaseInstallerTests.testReleaseCheckInstallAndRollbackWithSimulatedGitHub はGitHub APIの応答・配信を模擬し、旧版確認・ダウンロード・更新・設定保持・別拡張機能の拒否を検証する。認証付きGitHub APIへのXtend画面からの実通信とは区別する。


## 配布時の注意

- `.build/`、`DerivedData/`、`xcuserdata/`、`.ipa`、`.xcarchive`、署名鍵・証明書・プロビジョニングファイルをGitに追加しないでください。
- XのCookieやアカウント情報は端末のWebKitデータストアに保存されます。端末バックアップやSimulatorの端末データを配布しないでください。
- 外部から取得するChrome拡張機能のCRX・展開済みコード・配布ZIPをXtendへ同梱しないでください。
- ZIPからの拡張機能インストールでは、Chrome Web Storeの署名検証は行われません。