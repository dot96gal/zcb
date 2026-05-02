# zcli

## プロジェクトの概要

- Zig のサーキットブレーカーのライブラリを開発する

## 計画ファイル

- 計画ファイルは`.claude/plans/`ディレクトリに`YYYYMMDD_`の接頭辞を付与したファイル名で保存する

## 開発環境

- mise（zig のバージョンは `mise.toml` を参照）
- mise タスクでコマンドを実行する。利用可能なタスクは `mise.toml` を参照すること。

## 作業手順

- `.zig` ファイルを扱う前に必ず LSP ツール（`documentSymbol` / `hover` / `findReferences` / `goToDefinition`）を使うこと。Read/Grep は LSP が応答しない場合のフォールバック専用。

## 依存関係

- 外部ライブラリは使用しない。Zig 標準ライブラリ（`std`）のみを使用する

## コーディング規約

- [Zig スタイルガイド](https://ziglang.org/documentation/master/#Style-Guide) に従う。
