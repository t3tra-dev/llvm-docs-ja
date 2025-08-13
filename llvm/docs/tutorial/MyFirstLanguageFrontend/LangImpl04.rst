==============================================
Kaleidoscope: JITとオプティマイザーサポートの追加
==============================================

.. contents::
   :local:

第4章 はじめに
==============

「 `LLVMを使った言語実装 <index.html>`_」チュートリアルの第4章へようこそ。第1-3章ではシンプルな言語の実装とLLVM IRの生成サポートの追加について説明しました。この章では2つの新しい技法について説明します: 言語へのオプティマイザーサポートの追加とJITコンパイラーサポートの追加です。これらの追加により、Kaleidoscope言語で優雅で効率的なコードを得る方法を示します。

簡単な定数畳み込み
=================

第3章のデモンストレーションは優雅で拡張しやすいものでした。残念ながら、素晴らしいコードを生成しません。しかし、IRBuilderは、シンプルなコードをコンパイルするときに明らかな最適化を提供してくれます: 

::

    ready> def test(x) 1+2+x;
    関数定義を読み取り:
    define double @test(double %x) {
    entry:
            %addtmp = fadd double 3.000000e+00, %x
            ret double %addtmp
    }

このコードは、入力を解析して構築されたASTの文字通りの転写ではありません。それはこうなります: 

::

    ready> def test(x) 1+2+x;
    関数定義を読み取り:
    define double @test(double %x) {
    entry:
            %addtmp = fadd double 2.000000e+00, 1.000000e+00
            %addtmp1 = fadd double %addtmp, %x
            ret double %addtmp1
    }

上記のような定数畳み込みは、特に非常に一般的で非常に重要な最適化です: 多くの言語実装者がAST表現に定数畳み込みサポートを実装するほどです。

LLVMでは、ASTにこのサポートを含める必要はありません。LLVM IRを構築するすべての呼び出しはLLVM IRビルダーを通過するため、ビルダー自体が呼び出し時に定数畳み込みの機会があるかどうかをチェックします。もしあれば、命令を作成する代わりに定数畳み込みを実行し、定数を返します。

あ、簡単でした :) 。実際には、このようなコードを生成するときは常に ``IRBuilder`` を使用することを推奨します。使用に際して「構文オーバーヘッド」がなく (どこでも定数チェックでコンパイラーを醇くする必要がない) 、いくつかのケースで生成されるLLVM IRの量を劇的に減らすことができます (特にマクロプリプロセッサーを持つ言語や定数を多用する言語に対して) 。

一方、 ``IRBuilder`` は、コードが構築されるときにすべての分析をインラインで行うという事実によって制約されています。もう少し複雑な例を取ってみると: 

::

    ready> def test(x) (1+2+x)*(x+(1+2));
    ready> 関数定義を読み取り:
    define double @test(double %x) {
    entry:
            %addtmp = fadd double 3.000000e+00, %x
            %addtmp1 = fadd double %x, 3.000000e+00
            %multmp = fmul double %addtmp, %addtmp1
            ret double %multmp
    }

この場合、乗算のLHSとRHSは同じ値です。「 ``x+3``」を二度計算する代わりに「 ``tmp = x+3; result = tmp*tmp;``」を生成してくれることを望んでいます。

残念ながら、どんなにローカル分析を行っても、これを検出して修正することはできません。これには2つの変換が必要です: 式の再結合 (加算を辞書的に同一にするため) と共通部分式除去 (CSE) で冗長な加算命令を削除することです。幸いなことに、LLVMは「パス」の形で使用できる幅広い最適化を提供しています。

LLVM最適化パス
================

LLVMは多くの最適化パスを提供しており、さまざまな種類のことを行い、異なるトレードオフを持っています。他のシステムとは異なり、LLVMはすべての言語とすべての状況に対して1組の最適化が正しいという誤った概念を持ちません。LLVMはコンパイラー実装者が、どの最適化を使用し、どの順序で、どのような状況で使用するかについて完全な決定を下すことを可能にしています。

具体例として、LLVMは「モジュール全体」パスをサポートしており、これらは可能な限り大きなコード本体を横断的に見ます (多くの場合ファイル全体ですが、リンク時に実行された場合、プログラム全体のかなりの部分になることがあります)。また、他の関数を見ることなく一度に単一の関数でのみ動作する「関数ごと」パスもサポートしており、含んでいます。パスとその実行方法の詳細については、 `How to Write a Pass <../../WritingAnLLVMPass.html>`_ ドキュメントと `List of LLVM Passes <../../Passes.html>`_ を参照してください。

Kaleidoscopeでは、現在、ユーザーが入力するたびに関数を一つずつオンザフライで生成しています。この設定では究極の最適化体験を目指してはいませんが、可能な場合は簡単で迅速なものを捉えたいと思います。そのため、ユーザーが関数を入力する際にいくつかの関数ごとの最適化を実行することを選択します。「静的なKaleidoscopeコンパイラー」を作成したい場合は、ファイル全体が解析されるまで最適化の実行を延期する以外は、現在持っているコードとまったく同じものを使用するでしょう。

関数パスとモジュールパスの区別に加えて、パスは変換パスと解析パスに分けることができます。変換パスはIRを変更し、解析パスは他のパスが使用できる情報を計算します。変換パスを追加するために、それが依存するすべての解析パスを事前に登録する必要があります。

関数ごとの最適化を実行するために、実行したいLLVM最適化を保持し、組織化するための `FunctionPassManager <../../WritingAnLLVMPass.html#what-passmanager-doesr>`_ を設定する必要があります。それができたら、実行する最適化のセットを追加できます。最適化したい各モジュールに新しいFunctionPassManagerが必要なので、前の章で作成した関数 (``InitializeModule()``) に追加します:

.. code-block:: c++

    void InitializeModuleAndManagers(void) {
      // Open a new context and module.
      TheContext = std::make_unique<LLVMContext>();
      TheModule = std::make_unique<Module>("KaleidoscopeJIT", *TheContext);
      TheModule->setDataLayout(TheJIT->getDataLayout());

      // Create a new builder for the module.
      Builder = std::make_unique<IRBuilder<>>(*TheContext);

      // Create new pass and analysis managers.
      TheFPM = std::make_unique<FunctionPassManager>();
      TheLAM = std::make_unique<LoopAnalysisManager>();
      TheFAM = std::make_unique<FunctionAnalysisManager>();
      TheCGAM = std::make_unique<CGSCCAnalysisManager>();
      TheMAM = std::make_unique<ModuleAnalysisManager>();
      ThePIC = std::make_unique<PassInstrumentationCallbacks>();
      TheSI = std::make_unique<StandardInstrumentations>(*TheContext,
                                                        /*DebugLogging*/ true);
      TheSI->registerCallbacks(*ThePIC, TheMAM.get());
      ...

グローバルモジュール ``TheModule`` とFunctionPassManagerを初期化した後、フレームワークの他の部分を初期化する必要があります。4つのAnalysisManagerは、IR階層の4つのレベル全体で実行される解析パスを追加することを可能にします。PassInstrumentationCallbacksとStandardInstrumentationsは、開発者がパス間で何が起こるかをカスタマイズできるようにするパス計装フレームワークに必要です。

これらのマネージャーが設定されたら、一連の"addPass"呼び出しを使用して多くのLLVM変換パスを追加します: 

.. code-block:: c++

      // Add transform passes.
      // Do simple "peephole" optimizations and bit-twiddling optzns.
      TheFPM->addPass(InstCombinePass());
      // Reassociate expressions.
      TheFPM->addPass(ReassociatePass());
      // Eliminate Common SubExpressions.
      TheFPM->addPass(GVNPass());
      // Simplify the control flow graph (deleting unreachable blocks, etc).
      TheFPM->addPass(SimplifyCFGPass());

この場合、4つの最適化パスを追加することを選択します。ここで選択するパスは、幅広い種類のコードに有用な「クリーンアップ」最適化のかなり標準的なセットです。それらが何をするかについては深く立ち入りませんが、間違いなく良い出発点です :)。

次に、変換パスで使用される解析パスを登録します。

.. code-block:: c++

      // Register analysis passes used in these transform passes.
      PassBuilder PB;
      PB.registerModuleAnalyses(*TheMAM);
      PB.registerFunctionAnalyses(*TheFAM);
      PB.crossRegisterProxies(*TheLAM, *TheFAM, *TheCGAM, *TheMAM);
    }

PassManagerが設定されたら、それを使用する必要があります。これは、新しく作成された関数が構築された後 (``FunctionAST::codegen()`` 内で) に、しかしクライアントに返される前に実行することで行います: 

.. code-block:: c++

      if (Value *RetVal = Body->codegen()) {
        // Finish off the function.
        Builder.CreateRet(RetVal);

        // Validate the generated code, checking for consistency.
        verifyFunction(*TheFunction);

        // Optimize the function.
        TheFPM->run(*TheFunction, *TheFAM);

        return TheFunction;
      }

ご覧のように、これはかなり単純明快です。 ``FunctionPassManager`` はLLVM Function\* をその場で最適化および更新し、 (うまくいけば) その本体を改善します。これが配置されたことで、上記のテストを再び試すことができます: 

::

    ready> def test(x) (1+2+x)*(x+(1+2));
    ready> Read function definition:
    define double @test(double %x) {
    entry:
            %addtmp = fadd double %x, 3.000000e+00
            %multmp = fmul double %addtmp, %addtmp
            ret double %multmp
    }

期待通り、この関数の実行ごとに浮動小数点加算命令を節約して、素晴らしく最適化されたコードが得られるようになりました。

LLVMは特定の状況で使用できる多種多様な最適化を提供しています。 `様々なパスに関するドキュメント <../../Passes.html>`_ が利用可能ですが、あまり完全ではありません。アイデアのもう一つの良い情報源は、 ``Clang`` が実行するパスを見ることから得られます。"``opt``" ツールを使用すると、コマンドラインからパスを実験できるため、それらが何かを行うかどうかを確認できます。

フロントエンドから妥当なコードが出力されるようになったので、それを実行することについて説明しましょう！

JITコンパイラーを追加する
=====================

LLVM IRで利用可能なコードには、様々なツールを適用できます。たとえば、 (上記で行ったように) 最適化を実行したり、テキストまたはバイナリ形式でダンプしたり、何らかのターゲットに対してアセンブリファイル (.s) にコンパイルしたり、JITコンパイルしたりできます。LLVM IR表現の良い点は、コンパイラーの多くの異なる部分間で「共通通貨」であることです。

このセクションでは、インタープリターにJITコンパイラーサポートを追加します。Kaleidoscopeで望んでいる基本的なアイデアは、ユーザーが現在のように関数本体を入力しつつ、入力したトップレベル式を即座に評価することです。たとえば、"1 + 2;" と入力した場合、3を評価して印刷するべきです。関数を定義した場合、コマンドラインからそれを呼び出すことができるべきです。

これを行うために、まず現在のネイティブターゲット用のコードを作成するための環境を準備し、JITを宣言および初期化します。これは、いくつかの ``InitializeNativeTarget\*`` 関数を呼び出し、グローバル変数 ``TheJIT`` を追加し、 ``main`` で初期化することで行われます: 

.. code-block:: c++

    static std::unique_ptr<KaleidoscopeJIT> TheJIT;
    ...
    int main() {
      InitializeNativeTarget();
      InitializeNativeTargetAsmPrinter();
      InitializeNativeTargetAsmParser();

      // Install standard binary operators.
      // 1 is lowest precedence.
      BinopPrecedence['<'] = 10;
      BinopPrecedence['+'] = 20;
      BinopPrecedence['-'] = 20;
      BinopPrecedence['*'] = 40; // highest.

      // Prime the first token.
      fprintf(stderr, "ready> ");
      getNextToken();

      TheJIT = std::make_unique<KaleidoscopeJIT>();

      // Run the main "interpreter loop" now.
      MainLoop();

      return 0;
    }

また、JIT用のデータレイアウトも設定する必要があります: 

.. code-block:: c++

    void InitializeModuleAndPassManager(void) {
      // Open a new context and module.
      TheContext = std::make_unique<LLVMContext>();
      TheModule = std::make_unique<Module>("my cool jit", TheContext);
      TheModule->setDataLayout(TheJIT->getDataLayout());

      // Create a new builder for the module.
      Builder = std::make_unique<IRBuilder<>>(*TheContext);

      // Create a new pass manager attached to it.
      TheFPM = std::make_unique<legacy::FunctionPassManager>(TheModule.get());
      ...

KaleidoscopeJITクラスは、これらのチュートリアル専用に構築されたシンプルなJITで、LLVMソースコード内の `llvm-src/examples/Kaleidoscope/include/KaleidoscopeJIT.h <https://github.com/llvm/llvm-project/blob/main/llvm/examples/Kaleidoscope/include/KaleidoscopeJIT.h>`_ で利用可能です。後の章では、それがどのように動作するかを見て、新機能で拡張しますが、今のところは既存のものとして受け取ります。そのAPIは非常にシンプルです: ``addModule`` はLLVM IRモジュールをJITに追加し、その関数を実行可能にします (メモリは ``ResourceTracker`` によって管理される) ；また ``lookup`` はコンパイルされたコードへのポインターを検索することを可能にします。

このシンプルなAPIを使用して、トップレベル式を解析するコードを次のように変更できます: 

.. code-block:: c++

    static ExitOnError ExitOnErr;
    ...
    static void HandleTopLevelExpression() {
      // Evaluate a top-level expression into an anonymous function.
      if (auto FnAST = ParseTopLevelExpr()) {
        if (FnAST->codegen()) {
          // Create a ResourceTracker to track JIT'd memory allocated to our
          // anonymous expression -- that way we can free it after executing.
          auto RT = TheJIT->getMainJITDylib().createResourceTracker();

          auto TSM = ThreadSafeModule(std::move(TheModule), std::move(TheContext));
          ExitOnErr(TheJIT->addModule(std::move(TSM), RT));
          InitializeModuleAndPassManager();

          // Search the JIT for the __anon_expr symbol.
          auto ExprSymbol = ExitOnErr(TheJIT->lookup("__anon_expr"));
          assert(ExprSymbol && "Function not found");

          // Get the symbol's address and cast it to the right type (takes no
          // arguments, returns a double) so we can call it as a native function.
          double (*FP)() = ExprSymbol.getAddress().toPtr<double (*)()>();
          fprintf(stderr, "Evaluated to %f\n", FP());

          // Delete the anonymous expression module from the JIT.
          ExitOnErr(RT->remove());
        }

解析とコード生成が成功した場合、次のステップはトップレベル式を含むモジュールをJITに追加することです。これは、モジュール内のすべての関数のコード生成をトリガーし、後でJITからモジュールを削除するために使用できる ``ResourceTracker`` を受け取るaddModuleを呼び出すことで行います。モジュールがJITに追加されると、それ以上変更することはできないため、 ``InitializeModuleAndPassManager()`` を呼び出して後続のコードを保持する新しいモジュールも開きます。

モジュールをJITに追加したら、最終生成されたコードへのポインターを取得する必要があります。これは、JITの ``lookup`` メソッドを呼び出し、トップレベル式関数の名前: ``__anon_expr`` を渡すことで行います。この関数を追加したばかりなので、``lookup`` が結果を返すことをアサートします。

次に、シンボル上で ``getAddress()`` を呼び出すことで、 ``__anon_expr`` 関数のインメモリアドレスを取得します。トップレベル式を、引数を取らず、計算されたdoubleを返す独立したLLVM関数にコンパイルすることを思い出してください。LLVM JITコンパイラーはネイティブプラットフォームABIと一致するため、結果ポインターをその型の関数ポインターにキャストして直接呼び出すことができます。つまり、JITコンパイルされたコードとアプリケーションに静的にリンクされたネイティブマシンコードの間に違いはありません。

最後に、トップレベル式の再評価をサポートしていないため、完了時にJITからモジュールを削除して、関連するメモリを解放します。ただし、数行前に作成したモジュール (``InitializeModuleAndPassManager`` 経由) はまだ開いており、新しいコードが追加されるのを待っていることを思い出してください。

これらのたった2つの変更で、Kaleidoscopeが今どのように動作するかを見てみましょう！

::

    ready> 4+5;
    Read top-level expression:
    define double @0() {
    entry:
      ret double 9.000000e+00
    }

    Evaluated to 9.000000

これは基本的に動作しているように見えます。関数のダンプは、入力される各トップレベル式に対して合成する「常にdoubleを返す引数なし関数」を示しています。これは非常に基本的な機能を実証していますが、もっと多くのことができるでしょうか？

::

    ready> def testfunc(x y) x + y*2;
    Read function definition:
    define double @testfunc(double %x, double %y) {
    entry:
      %multmp = fmul double %y, 2.000000e+00
      %addtmp = fadd double %multmp, %x
      ret double %addtmp
    }

    ready> testfunc(4, 10);
    Read top-level expression:
    define double @1() {
    entry:
      %calltmp = call double @testfunc(double 4.000000e+00, double 1.000000e+01)
      ret double %calltmp
    }

    Evaluated to 24.000000

    ready> testfunc(5, 10);
    ready> LLVM ERROR: Program used external function 'testfunc' which could not be resolved!


関数定義と呼び出しも動作しますが、最後の行で何か非常に間違ったことが起きました。呼び出しは有効に見えるので、何が起きたのでしょうか？APIから推測されるかもしれませんが、ModuleはJITの割り当て単位であり、testfuncは匿名式を含む同じモジュールの一部でした。匿名式のメモリを解放するためにそのモジュールをJITから削除したとき、 ``testfunc`` の定義も一緒に削除しました。その後、testfuncを二度目に呼び出そうとしたとき、JITはもうそれを見つけることができませんでした。

これを修正する最も簡単な方法は、匿名式を他の関数定義とは別のモジュールに置くことです。JITは、呼び出される関数のそれぞれがプロトタイプを持ち、呼び出される前にJITに追加されている限り、モジュール境界を跨いだ関数呼び出しを幸いにも解決します。匿名式を別のモジュールに置くことで、他の関数に影響を与えることなくそれを削除できます。

実際には、さらに一歩進んで、すべての関数をそれぞれ独自のモジュールに置くつもりです。こうすることで、環境をよりREPL風にするKaleidoscopeJITの有用な特性を利用できます: 関数はJITに複数回追加できます (すべての関数が一意な定義を持たなければならないモジュールとは異なり) 。KaleidoscopeJITでシンボルを検索すると、常に最新の定義が返されます: 

::

    ready> def foo(x) x + 1;
    Read function definition:
    define double @foo(double %x) {
    entry:
      %addtmp = fadd double %x, 1.000000e+00
      ret double %addtmp
    }

    ready> foo(2);
    Evaluated to 3.000000

    ready> def foo(x) x + 2;
    define double @foo(double %x) {
    entry:
      %addtmp = fadd double %x, 2.000000e+00
      ret double %addtmp
    }

    ready> foo(2);
    Evaluated to 4.000000


各関数が独自のモジュールに生存できるようにするためには、開く各新しいモジュールに以前の関数宣言を再生成する方法が必要です: 

.. code-block:: c++

    static std::unique_ptr<KaleidoscopeJIT> TheJIT;

    ...

    Function *getFunction(std::string Name) {
      // First, see if the function has already been added to the current module.
      if (auto *F = TheModule->getFunction(Name))
        return F;

      // If not, check whether we can codegen the declaration from some existing
      // prototype.
      auto FI = FunctionProtos.find(Name);
      if (FI != FunctionProtos.end())
        return FI->second->codegen();

      // If no existing prototype exists, return null.
      return nullptr;
    }

    ...

    Value *CallExprAST::codegen() {
      // Look up the name in the global module table.
      Function *CalleeF = getFunction(Callee);

    ...

    Function *FunctionAST::codegen() {
      // Transfer ownership of the prototype to the FunctionProtos map, but keep a
      // reference to it for use below.
      auto &P = *Proto;
      FunctionProtos[Proto->getName()] = std::move(Proto);
      Function *TheFunction = getFunction(P.getName());
      if (!TheFunction)
        return nullptr;


これを有効にするために、まず各関数の最新のプロトタイプを保持する新しいグローバル ``FunctionProtos`` を追加します。また、 ``TheModule->getFunction()`` への呼び出しを置き換える便利メソッド ``getFunction()`` も追加します。私たちの便利メソッドは ``TheModule`` で既存の関数宣言を検索し、見つからない場合はFunctionProtosから新しい宣言を生成することにフォールバックします。 ``CallExprAST::codegen()`` では、 ``TheModule->getFunction()`` への呼び出しを置き換えるだけです。 ``FunctionAST::codegen()`` では、まずPunctionProtosマップを更新し、それから ``getFunction()`` を呼び出す必要があります。これで、以前に宣言された任意の関数について、現在のモジュール内で常に関数宣言を取得できるようになりました。

HandleDefinitionとHandleExternも更新する必要があります: 

.. code-block:: c++

    static void HandleDefinition() {
      if (auto FnAST = ParseDefinition()) {
        if (auto *FnIR = FnAST->codegen()) {
          fprintf(stderr, "Read function definition:");
          FnIR->print(errs());
          fprintf(stderr, "\n");
          ExitOnErr(TheJIT->addModule(
              ThreadSafeModule(std::move(TheModule), std::move(TheContext))));
          InitializeModuleAndPassManager();
        }
      } else {
        // Skip token for error recovery.
         getNextToken();
      }
    }

    static void HandleExtern() {
      if (auto ProtoAST = ParseExtern()) {
        if (auto *FnIR = ProtoAST->codegen()) {
          fprintf(stderr, "Read extern: ");
          FnIR->print(errs());
          fprintf(stderr, "\n");
          FunctionProtos[ProtoAST->getName()] = std::move(ProtoAST);
        }
      } else {
        // Skip token for error recovery.
        getNextToken();
      }
    }

HandleDefinitionでは、新しく定義された関数をJITに転送し、新しいモジュールを開くために2行を追加します。HandleExternでは、プロトタイプをFunctionProtosに追加するために1行だけ追加する必要があります。

.. warning::
    LLVM-9以降、別々のモジュール内でのシンボルの重複は許可されていません。これは、以下で示されるようにKaleidoscopeで関数を再定義できないことを意味します。この部分はスキップしてください。

    理由は、新しいOrcV2 JIT APIが静的および動的リンカーのルールに可能な限り近づこうとしており、重複シンボルの拒否も含まれているためです。シンボル名を一意にすることを要求することにより、 (一意の) シンボル名を追跡のキーとして使用して、シンボルの並行コンパイルをサポートできるようになります。

これらの変更を行ったら、再びREPLを試してみましょう (今回は匿名関数のダンプを削除しました。もうアイデアは分かっているはずです :) ) : 

::

    ready> def foo(x) x + 1;
    ready> foo(2);
    Evaluated to 3.000000

    ready> def foo(x) x + 2;
    ready> foo(2);
    Evaluated to 4.000000

動作します！

このシンプルなコードでも、驚くほど強力な機能が得られます - これをチェックしてください: 

::

    ready> extern sin(x);
    Read extern:
    declare double @sin(double)

    ready> extern cos(x);
    Read extern:
    declare double @cos(double)

    ready> sin(1.0);
    Read top-level expression:
    define double @2() {
    entry:
      ret double 0x3FEAED548F090CEE
    }

    Evaluated to 0.841471

    ready> def foo(x) sin(x)*sin(x) + cos(x)*cos(x);
    Read function definition:
    define double @foo(double %x) {
    entry:
      %calltmp = call double @sin(double %x)
      %multmp = fmul double %calltmp, %calltmp
      %calltmp2 = call double @cos(double %x)
      %multmp4 = fmul double %calltmp2, %calltmp2
      %addtmp = fadd double %multmp, %multmp4
      ret double %addtmp
    }

    ready> foo(4.0);
    Read top-level expression:
    define double @3() {
    entry:
      %calltmp = call double @foo(double 4.000000e+00)
      ret double %calltmp
    }

    Evaluated to 1.000000

おっと、JITはsinやcosについてどのように知っているのでしょうか？答えは驚くほどシンプルです: KaleidoscopeJITは、特定のモジュールで利用できないシンボルを見つけるために使用する単純なシンボル解決ルールを持っています: まず、最新から最古まで、JITにすでに追加されたすべてのモジュールを検索して、最新の定義を見つけます。JIT内で定義が見つからない場合、Kaleidoscopeプロセス自体で"``dlsym("sin")``"を呼び出すことにフォールバックします。"``sin``"がJITのアドレス空間内で定義されているため、モジュール内の呼び出しをlibm版の ``sin`` を直接呼び出すように単純にパッチします。しかし、いくつかのケースではこれはさらに進みます: sinやcosは標準数学関数の名前であるため、上記の"``sin(1.0)``"のように定数で呼び出されたとき、定数畳み込み器が関数呼び出しを正しい結果に直接評価します。

将来的には、このシンボル解決ルールを調整することで、セキュリティ (JITされたコードで利用可能なシンボルのセットを制限) から、シンボル名に基づいた動的コード生成、さらには遅延コンパイルまで、あらゆる種類の有用な機能を有効にするためにどのように使用できるかを見ていきます。

シンボル解決ルールの即座の利点の一つは、操作を実装するために任意のC++コードを書くことで言語を拡張できることです。たとえば、以下を追加する場合:

.. code-block:: c++

    #ifdef _WIN32
    #define DLLEXPORT __declspec(dllexport)
    #else
    #define DLLEXPORT
    #endif

    /// putchard - putchar that takes a double and returns 0.
    extern "C" DLLEXPORT double putchard(double X) {
      fputc((char)X, stderr);
      return 0;
    }

注意: Windowsでは、動的シンボルローダーが ``GetProcAddress`` を使用してシンボルを見つけるため、実際に関数をエクスポートする必要があります。
これで、「 ``extern putchard(x); putchard(120);``」のようなものを使用してコンソールにシンプルな出力を生成できます。これはコンソールに小文字の'x'を印刷します (120は'x'のASCIIコードです) 。同様のコードを使用して、Kaleidoscopeでファイル I/O、コンソール入力、その他多くの機能を実装できます。
これでKaleidoscopeチュートリアルのJITおよびオプティマイザーの章が完了しました。この時点で、チューリング非完全なプログラミング言語をコンパイルし、ユーザー主導で最適化およびJITコンパイルできます。
次は `制御フロー構成で言語を拡張 <LangImpl05.html>`_ し、その道筋で興味深いLLVM IRの問題に取り組んでいきます。

完全なコードリスト
=================

これはLLVM JITとオプティマイザーで拡張された実行中の例の完全なコードリストです。この例をビルドするには、以下を使用してください: 

.. code-block:: bash

    # Compile
    clang++ -g toy.cpp `llvm-config --cxxflags --ldflags --system-libs --libs core orcjit native` -O3 -o toy
    # Run
    ./toy

Linuxでコンパイルしている場合は、"-rdynamic"オプションも必ず追加してください。これにより、外部関数が実行時に正しく解決されることが保証されます。

コードはこちらです: 

.. literalinclude:: ../../../examples/Kaleidoscope/Chapter4/toy.cpp
   :language: c++

`次: 言語の拡張: 制御フロー <LangImpl05.html>`_

