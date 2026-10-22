<div align="center">
  <img src="./Logo.svg" alt="Xtend ロゴ" width="136">

  <h1>Xtend</h1>

  <p><strong>X向けのChrome拡張機能を、iPhoneでも。</strong></p>

  <p>iPhoneでXを閲覧するための、WebKitベースの専用アプリです。<br>拡張機能を入れずに、そのままXを使うこともできます。</p>
</div>

---

## できること

| 機能 | 内容 |
| --- | --- |
| **Xを閲覧** | iPhoneのWebKitでXを開き、ログイン状態を端末内に保持します。 |
| **拡張機能を追加** | 対応するChrome拡張機能をChrome Web StoreまたはローカルZIPから導入できます。 |
| **設定・更新** | 右上の設定から、拡張機能の一覧・削除・再読み込み・個別の設定を操作できます。 |

Xtendは**X専用**です。一般的なブラウザのアドレスバー、複数タブ、ブックマークはありません。すべてのChrome拡張機能やChrome APIに対応するものではありません。

## おすすめの拡張機能

### 🐈 [にゃっとランドforX](https://chromewebstore.google.com/detail/にゃっとランドforx/kchlmbffcbaambfigakeiamkhgacemng)

Xのタイムラインを猫たちが歩き、フォロー関係やいいね履歴なども表示するChrome拡張機能です。Xtendは、この拡張機能をiPhoneでも使うために作りました。初回画面または設定から任意で追加できます。

**作者：** [@karou2rikon](https://x.com/karou2rikon) · **配布：** [Chrome Web Store](https://chromewebstore.google.com/detail/にゃっとランドforx/kchlmbffcbaambfigakeiamkhgacemng)

### 📍 [x-home-anchor](https://github.com/akiweb8528/x-home-anchor)

Xホームで「新しいポストを表示」を押した後の閲覧位置を保持する補助拡張機能です。任意で導入できます。

GitHubリポジトリの**Releasesからビルド済みZIPをダウンロード**し、Xtendの設定にある「ZIPから読み込む」で追加してください。GitHubのソースZIPはそのままでは動きません。

## iPhoneへのインストール

**必要なもの：** macOS、iOS 18以降に対応するXcode、Apple IDでサインイン済みのXcode、USBまたはペアリング済みのiPhone（開発者モード有効）、[Homebrew](https://brew.sh/)。

1. このリポジトリをMacにダウンロードし、ターミナルでそのフォルダに移動します。
2. iPhoneをMacに接続して信頼設定を済ませ、下記の `xcrun devicectl list devices` で**端末ID**を確認します。Xcodeの **Settings → Accounts** で**Team ID**を確認します。
3. 以下の `TEAM_ID` と `DEVICE_ID` を自分の値に置き換え、リポジトリ直下でまとめて実行します。

```sh
brew install xcodegen
xcodegen generate
xcrun devicectl list devices

TEAM_ID="YOUR_TEAM_ID"
DEVICE_ID="YOUR_DEVICE_ID"
BUNDLE_ID="dev.$(whoami).xtend"

xcodebuild -project Xtend.xcodeproj -scheme Xtend \
  -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath .build/DerivedData \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Automatic build

xcrun devicectl device install app --device "$DEVICE_ID" \
  .build/DerivedData/Build/Products/Debug-iphoneos/Xtend.app
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
```

アプリが起動したら、必要に応じて「にゃっとランドforX」を追加するか、インストールせずにXを開けます。

> [!NOTE]
> 署名のために自分のApple IDとTeamが必要です。Bundle IDが他と重複する場合は `BUNDLE_ID` を変更してください。無料のPersonal Teamでは署名・プロビジョニングに制限があります。コマンドで署名が通らない場合は `open Xtend.xcodeproj` でXcodeを開き、**Signing & Capabilities** を確認してください。

Simulatorでのビルド、Xcodeによる実機インストール、ZIPのビルド手順は [開発者向けドキュメント](docs/DEVELOPMENT.md) にまとめています。

## 利用前の注意

> [!IMPORTANT]
> - **Googleアカウントを使ったXログイン**は、埋め込みWebViewに対するGoogleのOAuth制限により利用できない場合があります。Xのユーザー名・メールアドレス・電話番号でログインしてください。
> - WebKitベースでXにアクセスしますが、**X側によるアクセス制限やアカウントへの措置が生じないことは保証できません**。
> - Chrome拡張機能は第三者のプログラムです。配布元・権限・プライバシー条件を確認したうえで導入してください。**ローカルZIPはChrome Web Storeの署名検証を行いません**。

## ライセンスとプライバシー

Xtendの独自コードは [MIT License](LICENSE) です。ZIPの展開に利用する [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) もMITライセンスで、必要な表示は [LICENSE](LICENSE) に収録しています。外部の拡張機能にはそれぞれの配布条件が適用されます。

アプリ独自の分析サーバー、アカウントシステム、テレメトリーはありません。XのCookieと拡張機能の設定は端末内に保存されます。X閲覧時はXなどのWebサイトへ、拡張機能の取得時はGoogleの配信サービスなどへ通信します。拡張機能本体の動作や通信については各配布元の説明を確認してください。

XtendはX、Google、にゃっとランドforXの公式アプリではありません。にゃっとランドforXなどの第三者拡張機能の本体・画像・音声はリポジトリやアプリに同梱していません。

現行の実装仕様は [docs/SPEC.md](docs/SPEC.md) を参照してください。