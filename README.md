# Pindow

Windows用の常時最前面固定ツール。タイトルバーを左クリックしたまま(ドラッグ中)に右クリックすると、そのウィンドウの「常に最前面に表示」をON/OFFで切り替えます。固定中は4辺に赤い枠が表示されます。

AutoHotkey v2製。Per-Monitor V2 DPI対応の単体exeとしてビルドされているため、AutoHotkey本体が入っていないPCでも動作します。

## 使い方

1. [Releases](../../releases) から `PinWindow.exe` をダウンロード
2. 実行(初回はSmartScreenの確認が出るので「詳細情報」→「実行」)
3. 好きなウィンドウのタイトルバーを左クリックしたまま右クリック → 固定/解除

常駐させたい場合は、スタートアップフォルダ(`shell:startup`)に `PinWindow.exe` へのショートカットを置いてください。

## 開発

- `PinWindow.ahk` — ソース本体
- `PinWindow.manifest` — Per-Monitor V2 DPI宣言用マニフェスト
- `deploy.ps1` — ソースをコンパイル(Ahk2Exe)し、マニフェストを埋め込んでローカルに配置・再起動するスクリプト

`PinWindow.ahk` を編集したら `powershell -File deploy.ps1` を実行してください。
