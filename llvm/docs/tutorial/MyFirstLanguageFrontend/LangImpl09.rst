======================================
Kaleidoscope: デバッグ情報の追加
======================================

.. contents::
   :local:

第9章 はじめに
==============

「 `LLVMを使った言語実装 <index.html>`_」チュートリアルの第9章へようこそ。
第1章から第8章では、関数と変数を持つまともな小さなプログラミング言語を構築しました。
しかし、何か問題が発生した場合、プログラムをどのようにデバッグしますか？

ソースレベルデバッグでは、デバッガーがバイナリとマシンの状態から、
プログラマーが書いたソースに翻訳するのに役立つフォーマットされた
データを使用します。LLVMでは一般的に
`DWARF <http://dwarfstd.org>`_ と呼ばれる形式を使用します。
DWARFは、型、ソース位置、変数位置を表すコンパクトなエンコーディングです。

この章の短い要約は、デバッグ情報をサポートするためにプログラミング言語に
追加しなければならない様々なものを確認し、それをDWARFに翻訳する方法について
説明することです。

注意: 今のところJIT経由でのデバッグはできないので、プログラムを
小さく独立したものにコンパイルダウンする必要があります。
これの一環として、言語の実行方法とプログラムのコンパイル方法に
いくつかの修正を加えます。これは、インタラクティブなJITではなく、
Kaleidoscopeで書かれたシンプルなプログラムを含むソースファイルを
持つことを意味します。必要な変更の数を減らすために、一度に1つの
「トップレベル」コマンドのみを持つという制限があります。

コンパイルするサンプルプログラムは次の通りです: 

.. code-block:: python

   def fib(x)
     if x < 3 then
       1
     else
       fib(x-1)+fib(x-2);

   fib(10)


なぜこれは困難な問題なのか？
=========================

デバッグ情報は、いくつかの異なる理由で困難な問題です - 主に最適化されたコードを中心としています。第一に、最適化によりソース位置を保持することがより困難になります。LLVM IRでは、命令上の各IRレベル命令の元のソース位置を保持します。最適化パスは新しく作成された命令のソース位置を保持する必要がありますが、マージされた命令は単一の位置のみを保持することができます - これにより最適化されたプログラムをステップ実行する際にジャンプが発生する可能性があります。第二に、最適化は変数を最適化によって削除されるか、他の変数とメモリを共有するか、または追跡が困難な方法で移動させることができます。このチュートリアルの目的では最適化を避けます (次のパッチセットの1つで見るように) 。

事前コンパイルモード
==================

JITデバッグの複雑さを心配することなく、ソース言語にデバッグ情報を追加する側面のみを強調するために、フロントエンドから生成されるIRを実行、デバッグ、結果確認可能なシンプルなスタンドアロンプログラムにコンパイルすることをサポートするために、Kaleidoscopeにいくつかの変更を加えます。

まず、トップレベルステートメントを含む匿名関数を「main」にします: 

.. code-block:: udiff

  -    auto Proto = std::make_unique<PrototypeAST>("", std::vector<std::string>());
  +    auto Proto = std::make_unique<PrototypeAST>("main", std::vector<std::string>());

名前を付けるという単純な変更だけです。

次に、存在する場所でコマンドラインコードを削除します: 

.. code-block:: udiff

  @@ -1129,7 +1129,6 @@ static void HandleTopLevelExpression() {
   /// top ::= definition | external | expression | ';'
   static void MainLoop() {
     while (true) {
  -    fprintf(stderr, "ready> ");
       switch (CurTok) {
       case tok_eof:
         return;
  @@ -1184,7 +1183,6 @@ int main() {
     BinopPrecedence['*'] = 40; // highest.

     // 最初のトークンを準備
  -  fprintf(stderr, "ready> ");
     getNextToken();

最後に、すべての最適化パスとJITを無効にし、解析とコード生成が完了した後に起こることはLLVM IRが標準エラーに出力されるだけになるようにします: 

.. code-block:: udiff

  @@ -1108,17 +1108,8 @@ static void HandleExtern() {
   static void HandleTopLevelExpression() {
     // トップレベル式を匿名関数として評価
     if (auto FnAST = ParseTopLevelExpr()) {
  -    if (auto *FnIR = FnAST->codegen()) {
  -      // 実行を確実にするためだけにこれを行っている
  -      TheExecutionEngine->finalizeObject();
  -      // 関数をJITし、関数ポインターを返す
  -      void *FPtr = TheExecutionEngine->getPointerToFunction(FnIR);
  -
  -      // 正しい型にキャスト (引数なし、doubleを返す) して
  -      // ネイティブ関数として呼び出せるようにする
  -      double (*FP)() = (double (*)())(intptr_t)FPtr;
  -      // この戻り値は無視
  -      (void)FP;
  +    if (!FnAST->codegen()) {
  +      fprintf(stderr, "Error generating code for top level expr");
       }
     } else {
       // エラー復旧のためトークンをスキップ
  @@ -1439,11 +1459,11 @@ int main() {
     // target lays out data structures.
     TheModule->setDataLayout(TheExecutionEngine->getDataLayout());
     OurFPM.add(new DataLayoutPass());
  +#if 0
     OurFPM.add(createBasicAliasAnalysisPass());
     // allocaをレジスターに昇格
     OurFPM.add(createPromoteMemoryToRegisterPass());
  @@ -1218,7 +1210,7 @@ int main() {
     OurFPM.add(createGVNPass());
     // 制御フローグラフを簡略化 (到達不可能ブロックの削除など) 
     OurFPM.add(createCFGSimplificationPass());
  -
  +  #endif
     OurFPM.doInitialization();

     // コード生成が使用できるようにグローバルを設定

これら比較的小さな変更により、次のコマンドラインを使用してKaleidoscope言語の一部を実行可能プログラムにコンパイルできる状態になりました: 

.. code-block:: bash

  Kaleidoscope-Ch9 < fib.ks | & clang -x ir -

これにより、現在の作業ディレクトリにa.out/a.exeファイルが生成されます。

コンパイルユニット
================

DWARFにおけるコードセクションの最上位コンテナはコンパイルユニットです。これには個々の翻訳単位 (つまり: ソースコードの1つのファイル) の型と関数データが含まれています。そのため、まず最初に行う必要があるのはfib.ksファイル用のコンパイルユニットを構築することです。

DWARF生成の設定
================

``IRBuilder`` クラスと同様に、LLVM IRファイル用のデバッグメタデータの構築を支援する `DIBuilder <https://llvm.org/doxygen/classllvm_1_1DIBuilder.html>`_ クラスがあります。これは ``IRBuilder`` とLLVM IRに1対1で対応していますが、より良い名前を持っています。これを使用するには、 ``IRBuilder`` や ``Instruction`` の名前を使用する際に必要だったよりもDWARF用語により慣れ親しんでいる必要がありますが、 `メタデータフォーマット <https://llvm.org/docs/SourceLevelDebugging.html>`_ に関する一般的なドキュメントを読み通せば、もう少し明確になるでしょう。すべてのIRレベルの記述を構築するためにこのクラスを使用します。これを構築するにはモジュールが必要なので、モジュールを構築した直後に構築する必要があります。使いやすくするため、グローバルスタティック変数として残しています。

次に、頻繁に使用するデータをキャッシュする小さなコンテナを作成します。最初はコンパイルユニットですが、複数の型付き式を心配する必要がないため、単一の型用のコードも少し書きます:

.. code-block:: c++

  static std::unique_ptr<DIBuilder> DBuilder;

  struct DebugInfo {
    DICompileUnit *TheCU;
    DIType *DblTy;

    DIType *getDoubleTy();
  } KSDbgInfo;

  DIType *DebugInfo::getDoubleTy() {
    if (DblTy)
      return DblTy;

    DblTy = DBuilder->createBasicType("double", 64, dwarf::DW_ATE_float);
    return DblTy;
  }

そして後で ``main`` でモジュールを構築する際に: 

.. code-block:: c++

  DBuilder = std::make_unique<DIBuilder>(*TheModule);

  KSDbgInfo.TheCU = DBuilder->createCompileUnit(
      dwarf::DW_LANG_C, DBuilder->createFile("fib.ks", "."),
      "Kaleidoscope Compiler", false, "", 0);

ここで注意すべき点がいくつかあります。第一に、Kaleidoscopeという言語用のコンパイルユニットを生成しているにも関わらず、Cの言語定数を使用しています。これは、デバッガーが認識しない言語の呼び出し規約やデフォルトABIを必ずしも理解しないためであり、LLVM コード生成においてC ABIに従っているため、これが最も正確に近いものだからです。これにより、実際にデバッガーから関数を呼び出して実行させることができることが保証されます。第二に、 ``createCompileUnit`` の呼び出しで「fib.ks」が見えるでしょう。これは、シェルのリダイレクションを使用してソースをKaleidoscopeコンパイラーに入力するために使用するデフォルトのハードコードされた値です。通常のフロントエンドでは、入力ファイル名があり、それがここに入ります。

DIBuilder経由でデバッグ情報を生成する一部として最後に必要なのは、デバッグ情報を「完了」することです。その理由はDIBuilderの基本API の一部ですが、main の最後の近くで必ずこれを行ってください:

.. code-block:: c++

  DBuilder->finalize();

モジュールをダンプする前に実行します。

関数
====

``Compile Unit`` とソース位置ができたので、関数定義をデバッグ情報に追加できます。そのため ``FunctionAST::codegen()`` で、サブプログラム用のコンテキスト (この場合は「File」) と、関数自体の実際の定義を記述するコードを数行追加します。

コンテキストは次のとおりです: 

.. code-block:: c++

  DIFile *Unit = DBuilder->createFile(KSDbgInfo.TheCU->getFilename(),
                                      KSDbgInfo.TheCU->getDirectory());

これによりDIFileが得られ、現在の場所のディレクトリとファイル名について上で作成した ``Compile Unit`` に尋ねます。そして、現在のところ、ソース位置に0を使用し (ASTに現在ソース位置情報がないため) 、関数定義を構築します: 

.. code-block:: c++

  DIScope *FContext = Unit;
  unsigned LineNo = 0;
  unsigned ScopeLine = 0;
  DISubprogram *SP = DBuilder->createFunction(
      FContext, P.getName(), StringRef(), Unit, LineNo,
      CreateFunctionType(TheFunction->arg_size()),
      ScopeLine,
      DINode::FlagPrototyped,
      DISubprogram::SPFlagDefinition);
  TheFunction->setSubprogram(SP);

これで、関数のすべてのメタデータへの参照を含むDISubprogramができました。

ソース位置
==========

デバッグ情報で最も重要なのは正確なソース位置です。これによりソースコードを逆にマップすることが可能になります。ただし問題があります。Kaleidoscopeにはlexerやparserにソース位置情報が実際にはないため、これを追加する必要があります。

.. code-block:: c++

   struct SourceLocation {
     int Line;
     int Col;
   };
   static SourceLocation CurLoc;
   static SourceLocation LexLoc = {1, 0};

   static int advance() {
     int LastChar = getchar();

     if (LastChar == '\n' || LastChar == '\r') {
       LexLoc.Line++;
       LexLoc.Col = 0;
     } else
       LexLoc.Col++;
     return LastChar;
   }

このコードセットでは、「ソースファイル」の行と列を追跡する方法に関する機能を追加しました。すべてのトークンを字句解析する際に、現在の「語彙的位置」をトークンの開始に対する適切な行と列に設定します。これは、情報を追跡する新しい ``advance()`` で ``getchar()`` への以前のすべての呼び出しをオーバーライドすることで行い、その後すべてのASTクラスにソース位置を追加しました: 

.. code-block:: c++

   class ExprAST {
     SourceLocation Loc;

     public:
       ExprAST(SourceLocation Loc = CurLoc) : Loc(Loc) {}
       virtual ~ExprAST() {}
       virtual Value* codegen() = 0;
       int getLine() const { return Loc.Line; }
       int getCol() const { return Loc.Col; }
       virtual raw_ostream &dump(raw_ostream &out, int ind) {
         return out << ':' << getLine() << ':' << getCol() << '\n';
       }

新しい式を作成する際に受け渡すものです: 

.. code-block:: c++

   LHS = std::make_unique<BinaryExprAST>(BinLoc, BinOp, std::move(LHS),
                                          std::move(RHS));

各式と変数の位置を与えてくれます。

すべての命令が適切なソース位置情報を取得することを確実にするため、新しいソース位置にいるときはいつでも ``Builder`` に伝える必要があります。このために小さなヘルパー関数を使用します: 

.. code-block:: c++

  void DebugInfo::emitLocation(ExprAST *AST) {
    if (!AST)
      return Builder->SetCurrentDebugLocation(DebugLoc());
    DIScope *Scope;
    if (LexicalBlocks.empty())
      Scope = TheCU;
    else
      Scope = LexicalBlocks.back();
    Builder->SetCurrentDebugLocation(
        DILocation::get(Scope->getContext(), AST->getLine(), AST->getCol(), Scope));
  }

これは、主要な ``IRBuilder`` に現在位置を伝えると同時に、どのスコープにいるかも伝えます。スコープは、コンパイルユニットレベルか、現在の関数などの最も近い囲み語彙ブロックのいずれかです。これを表現するために、 ``DebugInfo`` でスコープのスタックを作成します: 

.. code-block:: c++

   std::vector<DIScope *> LexicalBlocks;

各関数のコードの生成を開始する際に、スコープ (関数) をスタックの先頭にプッシュします: 

.. code-block:: c++

  KSDbgInfo.LexicalBlocks.push_back(SP);

また、関数のコード生成の終了時に、スコープスタックからスコープをポップバックすることを忘れてはいけません: 

.. code-block:: c++

  // 無条件で追加したので、関数の語彙ブロックをポップオフ
  KSDbgInfo.LexicalBlocks.pop_back();

そして、新しいASTオブジェクトのコード生成を開始するたびに必ず位置を出力するようにします: 

.. code-block:: c++

   KSDbgInfo.emitLocation(this);

変数
====

関数ができたので、スコープ内にある変数を印刷できる必要があります。適切なバックトレースを取得し、関数がどのように呼び出されているかを確認できるように関数引数を設定しましょう。多くのコードではなく、一般的に ``FunctionAST::codegen`` で引数のallocaを作成する際にこれを処理します。

.. code-block:: c++

    // 関数引数をNamedValuesマップに記録
    NamedValues.clear();
    unsigned ArgIdx = 0;
    for (auto &Arg : TheFunction->args()) {
      // この変数用のallocaを作成
      AllocaInst *Alloca = CreateEntryBlockAlloca(TheFunction, Arg.getName());

      // 変数用のデバッグデスクリプターを作成
      DILocalVariable *D = DBuilder->createParameterVariable(
          SP, Arg.getName(), ++ArgIdx, Unit, LineNo, KSDbgInfo.getDoubleTy(),
          true);

      DBuilder->insertDeclare(Alloca, D, DBuilder->createExpression(),
                              DILocation::get(SP->getContext(), LineNo, 0, SP),
                              Builder->GetInsertBlock());

      // 初期値をallocaに保存
      Builder->CreateStore(&Arg, Alloca);

      // 引数を変数シンボルテーブルに追加
      NamedValues[std::string(Arg.getName())] = Alloca;
    }


ここでは、まず変数を作成し、スコープ ( ``SP`` ) 、名前、ソース位置、型を与え、引数であるため引数インデックスを与えます。次に、 ``#dbg_declare`` レコードを作成してIRレベルでalloca内に変数があることを示し (変数の開始位置を与えます) 、declare上のスコープの開始にソース位置を設定します。

ここで注意すべき興味深い点は、様々なデバッガーが過去にコードとデバッグ情報がどのように生成されていたかに基づく前提を持っていることです。この場合、関数プロローグの行情報を生成することを避けるために少しのハックが必要です。これにより、デバッガーがブレークポイントを設定する際にそれらの命令をスキップすることを認識できます。そのため ``FunctionAST::CodeGen`` でいくつかの行を追加します: 

.. code-block:: c++

  // プロローグ生成用の位置をアンセット (関数内で位置を持たない先頭命令は
  // プロローグの一部と見なされ、関数でブレークする際にデバッガーがそれらを
  // 通り過ぎて実行する) 
  KSDbgInfo.emitLocation(nullptr);

そして関数の本体のコード生成を実際に開始する際に新しい位置を出力します: 

.. code-block:: c++

  KSDbgInfo.emitLocation(Body.get());

これで、関数にブレークポイントを設定し、引数変数を印刷し、関数を呼び出すのに十分なデバッグ情報が得られました。ほんの数行のシンプルなコードにしては悪くありません！

完全なコードリスト
==================

これは実行中の例の完全なコードリストで、デバッグ情報で拡張されています。この例をビルドするには、次を使用してください: 

.. code-block:: bash

    # Compile
    clang++ -g toy.cpp `llvm-config --cxxflags --ldflags --system-libs --libs core orcjit native` -O3 -o toy
    # Run
    ./toy

コードは次の通りです: 

.. literalinclude:: ../../../examples/Kaleidoscope/Chapter9/toy.cpp
   :language: c++

`次: 結論とその他の有用なLLVMの情報 <LangImpl10.html>`_

