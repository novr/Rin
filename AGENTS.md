# AGENTS.md

## 概要
- この文書は、コードだけでは伝わらない非自明な運用ルールのみを定義する。

## コード規約
- ルール意味論（抽出・照合・違反判定）は AST ベースで実装する。
- `Rinfile.swift` デコードと evaluator 判定は `SwiftSyntax` / `SwiftParser` を使う。
- 禁止: `NSRegularExpression`、Swift `Regex`、文字列スライスによる意味論実装。
- 1ルール1責務を保ち、意図が名前と本文から読める DSL を維持する。
- DSL/API は表現力よりも意図の明確化を優先して追加する。

## テスト
- DSL デコードまたは evaluator 意味論を変更したら、両方の観点のテストを更新する。

## 境界
- Fail-closed を維持する。不確実な解析/評価は成功扱いにしない。
- 警告のみで `0` 終了するフォールバックは禁止。
- 終了コード契約は厳守する:
  - `0`: pass
  - `1`: policy violations
  - `2`: runtime/config/parser errors
- AST で構造的に実装できないルールは導入しない。

## GIT
- 変更は最小・意図保存で行い、大きな無関係リファクタは避ける。
- changelog は release note でのみ扱う（ファイル運用はしない）。
- コミットは関心ごとを分離し、差分に沿ったConventional Commitsを使う。
- 無関係ファイルはコミットに含めない。
- 非交渉ルール（AST-first / fail-closed / exit-code 契約）違反は PR reject 理由。
