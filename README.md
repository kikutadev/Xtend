<p align="center">
  <img src="./Logo.svg" alt="Xtend ロゴ" width="144">
</p>

# Xtend - Chrome拡張をiPhoneで使えるX専用アプリ

- Chrome拡張機能を追加してXを閲覧するiPhoneアプリです。拡張機能をインストールせずにXを見ることもできます。

## ご紹介

- [にゃっとランドforX](https://chromewebstore.google.com/detail/にゃっとランドforx/kchlmbffcbaambfigakeiamkhgacemng) ：このChrome拡張機能を使うためだけに作ったアプリでした。ぜひダウンロードして使ってみましょう
 作者様：[@karou2rikon](https://x.com/karou2rikon)
- 

注意！
- Googleアカウント経由のXログインは、埋め込みWebViewに対するGoogleのOAuth制限で動作を保証できません。Xのユーザー名・メールアドレス・電話番号でのログインを利用してください。（アプリ側で制限をかけています）
- Webkitベースの標準的なブラウザとして動作しています。しかし普通のアプリやWebブラウザとしては認識されない可能性もあります（作者本人が常用していてBAN等はされていませんが、X側の判断に依るため保証できません）。ご利用には十分ご注意をお願いいたします。
- Chrome拡張機能はPC上のChromeでの利用が通常であるところを、このアプリではiPhoneでの利用を可能にしています。Chrome拡張機能自体の安全性については本アプリの責務外であるとのご認識の上でご利用ください。

## iPhone実機へのインストール

1. `xcodegen generate` を実行し、`open Xtend.xcodeproj` でXcodeを開く。
2. `Xtend` ターゲットの **Signing & Capabilities** で自分のTeamを選ぶ。
3. **Bundle Identifier** をサンプルの `org.example.xtend` から自分だけのID（例: `dev.example.xtend.mybuild`）に変更する。
4. iPhoneを接続し、`Xtend` スキームの **Run** でビルド・インストールする。
5. 初回画面でおすすめの「にゃっとランドforX」を必要に応じてインストールするか、そのままXを開く。

署名設定は各自のXcode上で管理してください。`xcodegen generate` を再実行するとXcodeで変更した署名値が戻る場合があります。

`.build/`、`DerivedData/`、`xcuserdata/`、`.ipa`、`.xcarchive`、証明書関連ファイルはGit管理対象外です。アプリ内のXログインCookieはWebKitがインストール先の端末内で保持してください。Simulatorの端末データや実機バックアップを配布しないでください。

## ZIPから拡張機能を更新

右上の設定画面では、インストール済みChrome拡張機能の一覧と削除、ページの再読み込み、Web Storeからの取得、ZIPからのインストールができます。にゃっとランドの設定はインストール済み一覧の設定アイコンから開きます。ZIPはにゃっとランドforXかx-home-anchorのどちらかを検証して個別に導入します。

x-home-anchorのGitHubソースZIPはTypeScriptのままなので読み込めません。[上流の公開ソース](https://github.com/akiweb8528/x-home-anchor)からビルド済みZIPを作る例（Node.js 22.18以降）:

```sh
mkdir -p .build
git clone --depth 1 https://github.com/akiweb8528/x-home-anchor.git .build/x-home-anchor-src
cd .build/x-home-anchor-src
npm ci
npm run check
cd dist
zip -r ../../x-home-anchor.zip .
```

作成した `.build/x-home-anchor.zip` をiPhoneの「ファイル」に移して、「ZIPから読み込む」で選んでください。Xtend本体にはx-home-anchorの配布物を同梱しないので、使いたい場合はZIPからインストールします。

**ZIPの署名は確認されません。** manifest形式が正しくても安全性の保証にはならないので、信頼できるZIPだけ利用してください。


## Simulatorビルド

必要: macOS、iOS 18以降に対応したXcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。


```sh
brew install xcodegen        # 未インストールの場合
xcodegen generate
xcodebuild -project Xtend.xcodeproj -scheme Xtend \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

生成物: `.build/DerivedData/Build/Products/Debug-iphonesimulator/Xtend.app`

Releaseビルドは `-configuration Release` に変更します。生成物は `.build/DerivedData/Build/Products/Release-iphonesimulator/Xtend.app` です。**これらはSimulator専用で、iPhone実機用の署名はありません。**

起動済みのSimulatorに入れる例:

```sh
xcrun simctl install booted .build/DerivedData/Build/Products/Debug-iphonesimulator/Xtend.app
xcrun simctl launch booted org.example.xtend
```


## ライセンス

MIT

※拡張機能は、アプリの起動後、利用者がChrome Web Storeから取得する設計です。配信元が変わった場合には取得できない可能性があります。

ローカルZIPは利用者が内容と配布元を確認したファイルだけに使用してください。ZIP経路はChrome Web StoreのCRX署名検証を行いません。

このプロジェクトはX、Google、にゃっとランドforXの公式アプリではありません。

## プライバシー

アプリ独自の分析サーバー、アカウントシステム、テレメトリーはありません。X閲覧時はXなどのWebサイト、拡張機能の取得・更新時はGoogleの配信サービスに通信します。XのCookieはWebKitの永続データストア、拡張機能の設定は端末内に保存されます。

X上で動く「にゃっとランドforX」は外部から取得する第三者のプログラムです。インストールする際には配布元の説明やプライバシー条件を確認してください。