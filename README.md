# Xtend

iPhoneで[X](https://x.com/)を閲覧するためのWebKitベースの専用ブラウザです。Chrome拡張機能は任意で追加でき、インストールせずにXを閲覧することもできます。アドレスバー、タブ、ブックマークなどの汎用ブラウザ機能はありません。外部リンクはSafariで開き、Xの認証に必要なHTTPSリダイレクトはWebViewで処理します。

## 主な機能

- Xのログイン状態をiPhone内のWebKitデータストアに保存
- おすすめの[にゃっとランドforX](https://chromewebstore.google.com/detail/kchlmbffcbaambfigakeiamkhgacemng)をChrome Web Storeから任意で取得し、必要に応じて手動更新
- [x-home-anchor](https://github.com/akiweb8528/x-home-anchor)のビルド済みZIPを任意でインストールすると、Xホームの閲覧位置を保持
- 右上の設定から、インストール済み拡張機能の一覧・削除、Web Store・ZIPからの追加、Xページ再読み込み、にゃっとランドの設定を利用
- ZIPから、にゃっとランドforXとx-home-anchorを個別に更新

## クリーンなSimulatorビルド

必要: macOS、iOS 18以降に対応したXcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。Xのアカウント、Apple DeveloperのTeam ID、署名証明書、プロビジョニングファイルは**不要**です。

リポジトリ直下で実行:

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

## iPhone実機へのインストール

1. `xcodegen generate` を実行し、`open Xtend.xcodeproj` でXcodeを開く。
2. `Xtend` ターゲットの **Signing & Capabilities** で自分のTeamを選ぶ。
3. **Bundle Identifier** をサンプルの `org.example.xtend` から自分だけのID（例: `dev.example.xtend.mybuild`）に変更する。
4. iPhoneを接続し、`Xtend` スキームの **Run** でビルド・インストールする。
5. 初回画面でおすすめのChrome拡張機能を確認する。インストールするか、「インストールせずにXを見る」を選ぶ。

**Apple ID・Team ID・秘密鍵・証明書・XのCookieや認証情報をGitへ追加しないでください。** 署名設定は各自のXcode上で管理します。`xcodegen generate` を再実行するとXcodeで変更した署名値が戻る場合があります。

`.build/`、`DerivedData/`、`xcuserdata/`、`.ipa`、`.xcarchive`、証明書関連ファイルはGit管理対象外です。アプリ内のXログインCookieはWebKitがインストール先の端末内で保持し、ソースコードや通常の新規ビルドに同梱しません。Simulatorの端末データや実機バックアップを配布しないでください。

Googleアカウント経由のXログインは、埋め込みWebViewに対するGoogleのOAuth制限で動作を保証できません。Xのユーザー名・メールアドレス・電話番号でのログインを利用してください。

## ZIPから拡張機能を更新

右上の設定画面からインストール済みの拡張機能を確認・削除でき、追加後は「Xのページを再読み込み」で反映できます。にゃっとランドの設定は一覧の設定ボタンから開けます。ZIPは、にゃっとランドforXかx-home-anchorのどちらかを検証して個別にインストールします。

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

## ライセンスと第三者の著作物

アプリ本体の独自コードは[MIT License](LICENSE)です。ZIP展開に使う[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)もMITライセンスで、著作権表示と許諾文は[LICENSE](LICENSE)に収録しています。外部から取得する拡張機能にはそれぞれの配布元の条件が適用されます。

**にゃっとランドforXのCRX、展開済みコード、画像、音声はこのリポジトリに同梱していません。** アプリの起動後、利用者がChrome Web Storeから取得する設計です。配信元が変わった場合には取得できない可能性があります。

ローカルZIPは利用者が内容と配布元を確認したファイルだけに使用してください。ZIP経路はChrome Web StoreのCRX署名検証を行いません。

このプロジェクトはX、Google、にゃっとランドforXの公式アプリではありません。

## プライバシー

アプリ独自の分析サーバー、アカウントシステム、テレメトリーはありません。X閲覧時はXなどのWebサイト、拡張機能の取得・更新時はGoogleの配信サービスに通信します。XのCookieはWebKitの永続データストア、拡張機能の設定は端末内に保存されます。

X上で動く「にゃっとランドforX」は外部から取得する第三者のプログラムです。インストールする際には配布元の説明やプライバシー条件を確認してください。

## 技術仕様

[docs/SPEC.md](docs/SPEC.md)に実装契約と受け入れ条件を記載しています。
