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

## 配布時の注意

- `.build/`、`DerivedData/`、`xcuserdata/`、`.ipa`、`.xcarchive`、署名鍵・証明書・プロビジョニングファイルをGitに追加しないでください。
- XのCookieやアカウント情報は端末のWebKitデータストアに保存されます。端末バックアップやSimulatorの端末データを配布しないでください。
- 外部から取得するChrome拡張機能のCRX・展開済みコード・配布ZIPをXtendへ同梱しないでください。
- ZIPからの拡張機能インストールでは、Chrome Web Storeの署名検証は行われません。
