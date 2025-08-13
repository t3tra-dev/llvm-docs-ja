# LLVM ドキュメント日本語版

LLVMドキュメントの非公式日本語翻訳プロジェクトへようこそ！

## プロジェクトについて

このリポジトリは、LLVMコンパイラインフラストラクチャのドキュメントを
日本語に翻訳したものを含んでいます。LLVMは、高度に最適化された
コンパイラ、オプティマイザ、実行時環境を構築するためのツールキットです。

LLVMプロジェクトには複数のコンポーネントがあります。プロジェクトの
コア部分は「LLVM」と呼ばれ、中間表現を処理してオブジェクトファイルに
変換するために必要なすべてのツール、ライブラリ、ヘッダファイルが
含まれています。ツールには、アセンブラ、逆アセンブラ、ビットコード
アナライザ、ビットコードオプティマイザなどがあります。

C系言語には[Clang](https://clang.llvm.org/)フロントエンドを使用します。
このコンポーネントは、C、C++、Objective-C、Objective-C++コードを
LLVMビットコードにコンパイルし、そこからLLVMを使用してオブジェクト
ファイルに変換します。

その他のコンポーネントには、[libc++ C++標準ライブラリ](https://libcxx.llvm.org)、
[LLD リンカ](https://lld.llvm.org)などがあります。

## 翻訳の状況

このプロジェクトでは、LLVMの公式ドキュメントを日本語に翻訳しています。
現在翻訳中のコンポーネント:

- LLVM Core ドキュメント
- Clang ドキュメント  
- LLDB ドキュメント
- その他のLLVMサブプロジェクト

## ドキュメントの閲覧

翻訳されたドキュメントは `_site/` ディレクトリに生成されます。
`index.html` からメインページにアクセスできます。

## 翻訳への貢献

翻訳に貢献したい方は以下のガイドラインに従ってください:

1. **LLVM固有の用語** (LLVM、Clang、LLDB等) はそのまま使用
2. **自然な日本語**への翻訳を心がけ、直訳は避ける
3. **一貫性**のある用語使用を保つ
4. **技術的な正確性**を維持する

## 元のLLVMプロジェクト情報

LLVMプロジェクトの詳細情報については、以下を参照してください:

- [LLVM公式サイト](https://llvm.org/)
- [LLVM入門ガイド](https://llvm.org/docs/GettingStarted.html)
- [LLVMへの貢献方法](https://llvm.org/docs/Contributing.html)

## コミュニケーション

LLVMプロジェクトのコミュニティ:
- [LLVM Discourse フォーラム](https://discourse.llvm.org/)
- [Discord チャット](https://discord.gg/xS7Z362)
- [LLVM オフィスアワー](https://llvm.org/docs/GettingInvolved.html#office-hours)

LLVMプロジェクトの[行動規範](https://llvm.org/docs/CodeOfConduct.html)を採用しています。
