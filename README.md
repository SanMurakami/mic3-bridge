# DJI Mic 3 Bridge

複数のDJI Mic 3レシーバーをmacOSで使うためのアプリとCore Audioドライバーです。

※このプロジェクトの対応・検証対象はDJI Mic 3です。\
開発者が初代DJI Mic・DJI Mic 2・Mic Mini系を所有していないため、それらの対応・検証は行っていません。

## インストール

macOS 14以降と、XcodeまたはCommand Line Toolsが必要です。\
ソースからビルドしてインストールします。

```sh
./Install.command
```

導入には管理者認証が必要です。\
Core Audioが再起動するため、ほかの音声アプリも一時的に切断されます。\
初回起動時はマイクへのアクセスを許可してください。

削除には `Uninstall.command` を使います。

## 開発

```sh
bash scripts/build.sh
bash scripts/test.sh
```

`build.sh` はアプリとドライバーを `.build/` に生成し、ad-hoc署名を付けます。\
`test.sh` はドライバー、パケット処理、録音、ルーティングなどのテストを実行します。

サードパーティーライセンスは [vendor/apple-null-audio/LICENSE.txt](vendor/apple-null-audio/LICENSE.txt) に記載しています。
