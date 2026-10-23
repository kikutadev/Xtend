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

合成fixtureでZIPの不正パスとシンボリックリンク、破損パッケージの隔離、保存値の分離・変更通知、更新中断からの復旧を検証します。`XtendUITests`は既存のSimulator上でブラウザーが開ける場合に、設定画面の往復と手動再読み込みのUI操作を検証します。初回案内画面のままなら該当UIテストはスキップします。

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

X向けの小規模Chrome拡張機能は、**X専用Chromeプロファイル `~/.wxt-shared-chrome`** を共有します。通常のChromeプロファイルや他用途のWXT開発用プロファイルには影響させません。ログイン情報はこのChrome内に保持し、リポジトリや各拡張機能へCookieをコピーしません。

対象の独立したWXTプロジェクトは `../x-ad-hider/`、`../x-swipe-navigation/`、`../x-timeline-filter/` です。Timeline Filterは現状WXT開発環境だけの雛形で、投稿のフィルターは未実装です。

```sh
# pj/apps/Xtend から起動。既存のXログイン状態を再利用する
scripts/open-x-wxt-chrome.sh

# 各拡張機能ディレクトリのターミナルから
pnpm dev
```

WXT側の `web-ext.config.ts` は `disabled: true` とし、プロジェクトごとに新しいChromeを自動起動しません。表示中のX専用Chromeで `chrome://extensions/` を開き、デベロッパーモードをONにして各プロジェクトの `.output/chrome-mv3-dev/` を**それぞれ**「パッケージ化されていない拡張機能を読み込む」で追加します。ビルド済みの配布版を確認する場合は `.output/chrome-mv3/` を別途読み込みます。複数の拡張機能を同時に有効化できますが、設定は各拡張機能IDごとに独立します。

Chromeの拡張機能は一度読み込めば専用プロファイルに保存されます。更新時は必要に応じて拡張機能の再読み込みとXページの再読み込みを行います。単一のChromeプロファイルを別々のブラウザープロセスで同時起動しません。

**X向け拡張機能を今後追加する場合：** そのWXTプロジェクトに次の設定を追加し、上記のX専用Chromeへ読み込みます。これにより他用途のWXTプロジェクトへ共有設定を広げず、X向けだけを明示的に参加させます。

```ts
// web-ext.config.ts
import { defineWebExtConfig } from 'wxt';
export default defineWebExtConfig({ disabled: true });
```

`x-swipe-navigation/qa/live-smoke.mjs` は、既存の別プロファイル（`.dev/chrome-profile`、CDP 9317）に依存する検証スクリプトです。これは共通プロファイルへ自動移行しません。**X向けの手動・統合検証**では上記の共通Chromeを使い、CDP検証のプロファイルは用途を分けます。

## X Swipe Navigation（独立WXT拡張機能）

ソースはXtendと同じ親ディレクトリの `../x-swipe-navigation/` にあります。Xtendへソースコードは同梱しません。

```sh
cd ../x-swipe-navigation
pnpm install
pnpm typecheck
pnpm build
pnpm test
pnpm zip
# .output/x-swipe-navigation-0.1.0-chrome.zip が生成されます
```

WXT開発サーバー `pnpm dev` を起動している場合は `node qa/e2e.mjs --dev` で開発ビルドも検証できます。ログイン済みXをCDPポート9317で開いている開発環境では `node qa/live-smoke.mjs` でXの実DOMに対するテストを実施できます。ライブスモーク検証専用のChromeプロファイルは `.dev/` 以下でGit対象外です。通常のX向けWXT開発は上記の共通プロファイルを利用します。

iPhoneの「ファイル」にZIPを保存し、Xtendの設定または初回案内の「ZIPでインストール」から選択します。3種類の拡張機能は別々に検証・保存・削除されます。ソースZIPや `.output/chrome-mv3-dev` を指定せず、本番の `pnpm zip` で生成したZIPを使います。

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

画像判定はXの明るいテーマ・現在のモバイルレイアウト向けの補助検証で、固定座標に投稿の動画や操作ボタンが現れた場合はジェスチャーが意図的に無効化されることがあります。**XCTestの終了コードだけで切替成功と判断しない**こと。Simulatorでの確認は実iPhoneの性能・WKWebViewの競合を保証しません。既存アプリコンテナへの拡張機能の一時配置は、ZIP選択画面を通した導入の検証には含めません。

## 配布時の注意

- `.build/`、`DerivedData/`、`xcuserdata/`、`.ipa`、`.xcarchive`、署名鍵・証明書・プロビジョニングファイルをGitに追加しないでください。
- XのCookieやアカウント情報は端末のWebKitデータストアに保存されます。端末バックアップやSimulatorの端末データを配布しないでください。
- 外部から取得するChrome拡張機能のCRX・展開済みコード・配布ZIPをXtendへ同梱しないでください。
- ZIPからの拡張機能インストールでは、Chrome Web Storeの署名検証は行われません。