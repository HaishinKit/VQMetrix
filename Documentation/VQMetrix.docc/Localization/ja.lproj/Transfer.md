# 端末からMacへ転送する

Macで「端末から受信」を開始すると、同じLANへBonjourサービス`_vqmetrix._tcp.`を公開します。
Android Exampleで受信先を選び、Macに表示されるセッションごとの4桁の接続コードを入力します。
Macはパッケージを検証し、順にVMAF評価を行って履歴へ保存します。

## ネットワークと接続コード

内蔵のMac受信機は信頼できるLAN向けのHTTPです。接続コードは暗号化の代わりではありません。
インターネットへ直接公開しないでください。コードの連続した誤入力は回数制限されます。
転送クライアントはHTTPSにも対応しますが、内蔵受信機がHTTPSを提供するわけではありません。

Bonjourで見つからない場合は、両端末が同じネットワークにいるか、ローカルネットワークの許可と
ファイアウォールの設定を確認します。受信を停止するとサービスの公開も停止します。

## Android側の役割

収録・再エンコード・アップロードUIはHaishinKit.ktのExampleにあります。
VQMetrixのAndroidライブラリーは発見と転送を提供し、HaishinKit本体には依存しません。

ZIPには参照YUV、各コーデックの映像、フレームの対応情報、チェックサムと任意の負荷情報を含めます。
動画のみを対象とし、音声は評価しません。破損したファイルやパスの不正を含むZIPは受け付けません。
詳細な形式は[転送仕様](https://github.com/HaishinKit/VQMetrix/blob/main/docs/transfer.md)を参照してください。

## Language / 言語

[English](https://haishinkit.github.io/VQMetrix/swift/documentation/vqmetrix/transfer/) · [日本語](https://haishinkit.github.io/VQMetrix/ja/swift/documentation/vqmetrix/transfer/)
