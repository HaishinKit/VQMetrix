# 端末側の負荷データ

Android Exampleがアップロードする各ビットレートの映像には、再エンコード時の負荷を付けられます。

- 処理時間、FPS、映像時間に対する処理速度
- フレーム投入からエンコード出力までの平均・p95遅延と最初の出力までの時間
- アプリ全体のCPU時間、CPUコア数換算の平均使用量
- メモリーのPSSサンプルと、サンプル中の最大値
- OSが提供する発熱状態

これは保存した参照映像のオフライン再エンコード計測です。ライブ配信全体の遅延や、
エンコーダー専用のハードウェア使用率ではありません。CPU・メモリーにはアプリの他の処理も含まれます。
発熱状態は温度の実測値ではなくOSの区分です。サンプリング間のピークは見落とす可能性があります。

フレームの遅延はPTSで対応付けます。出力を受け取る前後のどこを計測するかによって値は変わります。
異なる実装・端末間の比較では、同じ条件かを確認してください。

iOSで同じ形式を送れる共通スキーマはありますが、このリリースにiOS用の収録・負荷収集アプリは含みません。
負荷情報がない旧パッケージも評価できます。

## Language / 言語

[English](https://haishinkit.github.io/VQMetrix/swift/documentation/vqmetrix/performancemetrics/) · [日本語](https://haishinkit.github.io/VQMetrix/ja/swift/documentation/vqmetrix/performancemetrics/)
