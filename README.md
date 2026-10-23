<div align="center">
  <img src="./Logo.svg" alt="Xtend ロゴ" width="144">
  <h1>Xtend</h1>
  <p><strong>Chrome拡張をiPhoneで使えるX専用アプリ</strong></p>
</div>

- Chrome拡張機能を追加してXを閲覧するiPhoneアプリです。拡張機能をインストールせずにXを見ることもできます。

## おすすめの拡張機能

[にゃっとランドforX](https://chromewebstore.google.com/detail/にゃっとランドforx/kchlmbffcbaambfigakeiamkhgacemng) ：このChrome拡張機能を使うためだけに作ったアプリでした。ぜひダウンロードして使ってみましょう
 作者様：[@karou2rikon](https://x.com/karou2rikon)

## 注意事項

- Googleアカウント経由のXログインは、埋め込みWebViewに対するGoogleのOAuth制限で動作を保証できません。Xのユーザー名・メールアドレス・電話番号でのログインを利用してください。（アプリ側で制限をかけています）
- Webkitベースの標準的なブラウザとして動作しています。しかし普通のアプリやWebブラウザとしては認識されない可能性もあります（作者本人が常用していてBAN等はされていませんが、X側の判断に依るため保証できません）。ご利用には十分ご注意をお願いいたします。
- Chrome拡張機能はPC上のChromeでの利用が通常であるところを、このアプリではiPhoneでの利用を可能にしています。Chrome拡張機能自体の安全性については本アプリの責務外であるとのご認識の上でご利用ください。

## iPhoneへのインストール

**必要なもの：** macOS、iOS 18以降に対応するXcode、Apple IDでサインイン済みのXcode、USBまたはペアリング済みのiPhone（開発者モード有効）、[Homebrew](https://brew.sh/)。

1. このリポジトリをMacにダウンロードし、ターミナルでそのフォルダに移動します。
2. **Team ID（10文字）**：Xcodeの **Settings → Accounts** にApple Accountを追加します。
   - Apple Developer Program加入者： [Apple Developerのアカウント](https://developer.apple.com/account/) → **メンバーシップの詳細** に表示されます。
   - 無料の **Personal Team**：下のコードの `brew install xcodegen` と `xcodegen generate` を先に実行し、`open Xtend.xcodeproj` → **Xtend → Signing & Capabilities → Team** でPersonal Teamを選択。その後 `xcodebuild -project Xtend.xcodeproj -scheme Xtend -showBuildSettings | grep DEVELOPMENT_TEAM` に表示されるIDを使います。
3. **端末ID**：iPhoneをMacに接続し「信頼」を選択します。`xcrun devicectl list devices` の一覧で、iPhoneの行の **Identifier** をコピーします（**physical** の端末を選び、**simulated** は選ばない）。
4. 下の `TEAM_ID="YOUR_TEAM_ID"` と `DEVICE_ID="YOUR_DEVICE_ID"` を取得した値に書き換え、コマンドを実行します。

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

## ZIPから拡張機能を更新

右上の設定画面では、インストール済みChrome拡張機能の一覧と削除、ページの再読み込み、Web Storeからの取得、ZIPからのインストールができます。にゃっとランドの設定はインストール済み一覧の設定アイコンから開きます。ZIPはにゃっとランドforXかx-home-anchorのどちらかを検証して個別に導入します。

x-home-anchorは[GitHubリポジトリ](https://github.com/akiweb8528/x-home-anchor)のReleasesからビルド済みZIPを取得し、「ZIPから読み込む」で追加できます。ソースからのZIP作成手順は[開発者向けドキュメント](docs/DEVELOPMENT.md)を参照してください。

## ライセンス

MIT

※拡張機能は、アプリの起動後、利用者がChrome Web Storeから取得する設計です。配信元が変わった場合には取得できない可能性があります。

ローカルZIPは利用者が内容と配布元を確認したファイルだけに使用してください。ZIP経路はChrome Web StoreのCRX署名検証を行いません。

このプロジェクトはX、Google、にゃっとランドforXの公式アプリではありません。

## プライバシー

アプリ独自の分析サーバー、アカウントシステム、テレメトリーはありません。X閲覧時はXなどのWebサイト、拡張機能の取得・更新時はGoogleの配信サービスに通信します。XのCookieはWebKitの永続データストア、拡張機能の設定は端末内に保存されます。

X上で動く「にゃっとランドforX」は外部から取得する第三者のプログラムです。インストールする際には配布元の説明やプライバシー条件を確認してください。
