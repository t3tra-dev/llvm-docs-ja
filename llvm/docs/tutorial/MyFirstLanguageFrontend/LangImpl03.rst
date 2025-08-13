==============================
Kaleidoscope: LLVM IRへのコード生成
==============================

.. contents::
   :local:

第3章 はじめに
===============

「 `LLVMを使った言語実装 <index.html>`_」チュートリアルの第3章へようこそ。この章では、第2章で構築した `抽象構文木 <LangImpl02.html>`_ をLLVM IRに変換する方法を示します。これにより、LLVMがどのように動作するかを少し学び、同時にそれがいかに使いやすいかを実証します。lexerとparserを構築するよりも、LLVM IRコードを生成する方がはるかに作業が少ないのです。:)

**注意してください**: この章以降のコードは、LLVM 3.7以降を必要とします。LLVM 3.6以前では動作しません。また、使用するLLVMリリースに一致するバージョンのチュートリアルを使用する必要があります: 公式のLLVMリリースを使用している場合は、リリースに含まれているバージョンのドキュメント、または `llvm.org releases page <https://llvm.org/releases/>`_ のバージョンを使用してください。

コード生成の設定
=================

LLVM IRを生成するために、始めるための簡単な設定が必要です。まず、各ASTクラスに仮想コード生成 (codegen) メソッドを定義します: 

.. code-block:: c++

    /// ExprAST - すべての式ノードのベースクラス
    class ExprAST {
    public:
      virtual ~ExprAST() = default;
      virtual Value *codegen() = 0;
    };

    /// NumberExprAST - "1.0"のような数値リテラル用の式クラス
    class NumberExprAST : public ExprAST {
      double Val;

    public:
      NumberExprAST(double Val) : Val(Val) {}
      Value *codegen() override;
    };
    ...

codegen()メソッドは、そのASTノードとそれが依存するすべてのものに対してIRを発行し、すべてがLLVM Valueオブジェクトを返すことを意味します。"Value"は、LLVMで"静的単一代入 (Static Single Assignment, `SSA <http://en.wikipedia.org/wiki/Static_single_assignment_form>`_) レジスタ"または"SSA値"を表すために使用されるクラスです。SSA値の最も特徴的な側面は、その値が関連する命令が実行されるときに計算され、命令が再実行されるまで (した場合) 新しい値を取得しないことです。言い換えると、SSA値を「変更」する方法はありません。詳細については、`静的単一代入 <http://en.wikipedia.org/wiki/Static_single_assignment_form>`_ について読んでください - 一度理解すると、概念は本当に非常に自然です。

ExprASTクラス階層に仮想メソッドを追加する代わりに、`ビジターパターン <http://en.wikipedia.org/wiki/Visitor_pattern>`_ や他の方法でこれをモデル化することも理にかなっていることに注意してください。繰り返しますが、このチュートリアルでは優れたソフトウェアエンジニアリングプラクティスにはこだわりません: 私たちの目的のためには、仮想メソッドを追加するのが最も簡単です。

次に必要なのは、parserで使用したような"LogError"メソッドで、これはコード生成中に発見されたエラー (例: 未宣言パラメータの使用) を報告するために使用されます: 

.. code-block:: c++

    static std::unique_ptr<LLVMContext> TheContext;
    static std::unique_ptr<IRBuilder<>> Builder;
    static std::unique_ptr<Module> TheModule;
    static std::map<std::string, Value *> NamedValues;

    Value *LogErrorV(const char *Str) {
      LogError(Str);
      return nullptr;
    }

これらのstatic変数はコード生成中に使用されます。``TheContext`` は型テーブルや定数値テーブルなど、多くのコアLLVMデータ構造を所有する不透明なオブジェクトです。詳細を理解する必要はなく、これを必要とするAPIに渡す単一のインスタンスがあれば十分です。

``Builder`` オブジェクトは、LLVM命令の生成を簡単にするヘルパーオブジェクトです。 `IRBuilder <https://llvm.org/doxygen/IRBuilder_8h_source.html>`_ クラステンプレートのインスタンスは、命令を挿入する現在位置を追跡し、新しい命令を作成するメソッドを持っています。

``TheModule`` は関数とグローバル変数を含むLLVM構成体です。多くの点で、LLVM IRがコードを含めるために使用するトップレベル構造です。生成するすべてのIRのメモリを所有するため、codegen()メソッドはunique_ptr<Value>ではなく、生のValue*を返します。

``NamedValues`` マップは、現在のスコープで定義されている値とそのLLVM表現が何であるかを追跡します (つまり、コードのシンボルテーブルです) 。この形のKaleidoscopeでは、参照できるものは関数パラメータのみです。そのため、関数本体のコードを生成するときに、関数パラメータがこのマップに含まれることになります。

これらの基本が整ったところで、各式のコード生成方法について話し始めることができます。これは ``Builder`` が何かにコードを生成*する*ように設定されていることを前提としていることに注意してください。今のところ、これがすでに行われていると仮定し、コードを発行するためにそれを使用するだけです。

式のコード生成
================

式ノード用のLLVMコードの生成は非常に分かりやすく、4つの式ノードすべてに対してコメント付きで45行未満のコードです。まず数値リテラルから始めましょう: 

.. code-block:: c++

    Value *NumberExprAST::codegen() {
      return ConstantFP::get(*TheContext, APFloat(Val));
    }

LLVM IRでは、数値定数は ``ConstantFP`` クラスで表され、内部的に ``APFloat`` で数値を保持します (``APFloat`` は任意精度の浮動小数点定数を保持する機能を持っています) 。このコードは基本的に ``ConstantFP`` を作成して返すだけです。LLVM IRでは、定数はすべて一意化されて共有されることに注意してください。そのため、APIは "new foo(..)" や "foo::Create(..)" の代わりに"foo::get(...)" イディオムを使用します。

.. code-block:: c++

    Value *VariableExprAST::codegen() {
      // 関数内でこの変数を検索
      Value *V = NamedValues[Name];
      if (!V)
        LogErrorV("Unknown variable name");
      return V;
    }

変数への参照もLLVMを使用すると非常にシンプルです。Kaleidoscopeのシンプル版では、変数がすでにどこかで発行されており、その値が利用可能であると仮定します。実際には、``NamedValues`` マップに含まれる値は関数の引数のみです。このコードは、指定された名前がマップにあるかどうかを確認し (ない場合は未知の変数が参照されています) 、その値を返します。将来の章では、シンボルテーブルに `ループ誘導変数 <LangImpl05.html#for-loop-expression>`_ と `ローカル変数 <LangImpl07.html#user-defined-local-variables>`_ のサポートを追加します。

.. code-block:: c++

    Value *BinaryExprAST::codegen() {
      Value *L = LHS->codegen();
      Value *R = RHS->codegen();
      if (!L || !R)
        return nullptr;

      switch (Op) {
      case '+':
        return Builder->CreateFAdd(L, R, "addtmp");
      case '-':
        return Builder->CreateFSub(L, R, "subtmp");
      case '*':
        return Builder->CreateFMul(L, R, "multmp");
      case '<':
        L = Builder->CreateFCmpULT(L, R, "cmptmp");
        // bool 0/1をdouble 0.0または1.0に変換
        return Builder->CreateUIToFP(L, Type::getDoubleTy(*TheContext),
                                     "booltmp");
      default:
        return LogErrorV("invalid binary operator");
      }
    }

二項演算子はより興味深くなり始めます。ここでの基本的なアイデアは、式の左辺のコードを再帰的に発行し、次に右辺、そして二項式の結果を計算することです。このコードでは、適切なLLVM命令を作成するためにオペコードに対して単純なswitchを実行します。

上記の例では、LLVMビルダークラスがその価値を示し始めています。IRBuilderは新しく作成された命令をどこに挿入するかを知っており、あなたがすることは、作成する命令 (例: ``CreateFAdd``) 、使用するオペランド (ここでは ``L`` と ``R``) を指定し、オプションで生成された命令の名前を提供することだけです。

LLVMの優れた点の一つは、名前が単なるヒントであることです。たとえば、上記のコードが複数の"addtmp"変数を発行する場合、LLVMは自動的にそれぞれに増加する一意の数値サフィックスを提供します。命令のローカル値名は純粋にオプションですが、IRダンプを読むのがはるかに簡単になります。

`LLVM命令 <../../LangRef.html#instruction-reference>`_ は厳格なルールによって制約されます: たとえば、 `add命令 <../../LangRef.html#add-instruction>`_ の左右のオペランドは同じ型である必要があり、addの結果型はオペランド型と一致する必要があります。Kaleidoscopeのすべての値はdoubleであるため、add、sub、mulに対して非常にシンプルなコードになります。

一方、LLVMは `fcmp命令 <../../LangRef.html#fcmp-instruction>`_ が常に'i1'値 (1ビット整数) を返すことを指定しています。これの問題は、Kaleidoscopeが値を0.0または1.0の値にしたいということです。これらのセマンティクスを取得するために、fcmp命令を `uitofp命令 <../../LangRef.html#uitofp-to-instruction>`_ と組み合わせます。この命令は、入力を符号なし値として扱うことで、入力整数を浮動小数点値に変換します。対照的に、 `sitofp命令 <../../LangRef.html#sitofp-to-instruction>`_ を使用した場合、Kaleidoscopeの'<'演算子は入力値に応じて0.0と-1.0を返すでしょう。

.. code-block:: c++

    Value *CallExprAST::codegen() {
      // グローバルモジュールテーブルで名前を検索
      Function *CalleeF = TheModule->getFunction(Callee);
      if (!CalleeF)
        return LogErrorV("Unknown function referenced");

      // 引数の不一致エラーのチェック
      if (CalleeF->arg_size() != Args.size())
        return LogErrorV("Incorrect # arguments passed");

      std::vector<Value *> ArgsV;
      for (unsigned i = 0, e = Args.size(); i != e; ++i) {
        ArgsV.push_back(Args[i]->codegen());
        if (!ArgsV.back())
          return nullptr;
      }

      return Builder->CreateCall(CalleeF, ArgsV, "calltmp");
    }

LLVM による関数呼び出しのコード生成は非常に分かりやすいものです。上記のコードは最初にLLVMモジュールのシンボルテーブルで関数名の検索を行います。LLVMモジュールはJITコンパイルしている関数を保持するコンテナであることを思い出してください。各関数にユーザーが指定したものと同じ名前を付けることで、LLVMシンボルテーブルを使用して関数名を解決できます。

呼び出す関数が決まったら、渡される各引数を再帰的にコード生成し、LLVM `call命令 <../../LangRef.html#call-instruction>`_ を作成します。LLVMはデフォルトでネイティブC呼び出し規約を使用するため、これらの呼び出しは追加の労力なしに"sin"や"cos"などの標準ライブラリ関数も呼び出すことができることに注意してください。

これで、Kaleidoscopeで現在持っている4つの基本式の処理が完了しました。ぜひもっと追加してみてください。たとえば、`LLVM言語リファレンス <../../LangRef.html>`_ を参照すると、基本フレームワークに簡単に組み込むことができる興味深い他の命令がいくつか見つかるでしょう。

関数のコード生成
================

プロトタイプと関数のコード生成は多くの詳細を処理する必要があり、式のコード生成ほど美しくありませんが、いくつかの重要な点を説明できます。まず、プロトタイプのコード生成について話しましょう: これらは関数本体と外部関数宣言の両方で使用されます。コードは次のように始まります: 

.. code-block:: c++

    Function *PrototypeAST::codegen() {
      // 関数型を作成:  double(double,double) など
      std::vector<Type*> Doubles(Args.size(),
                                 Type::getDoubleTy(*TheContext));
      FunctionType *FT =
        FunctionType::get(Type::getDoubleTy(*TheContext), Doubles, false);

      Function *F =
        Function::Create(FT, Function::ExternalLinkage, Name, TheModule.get());

このコードは数行に多くの機能を詰め込んでいます。まず、この関数が"Value*"ではなく"Function*"を返すことに注意してください。"prototype"は実際には関数の外部インターフェース (式で計算される値ではない) について話しているため、コード生成時に対応するLLVM関数を返すことは理にかなっています。

``FunctionType::get`` の呼び出しは、与えられたPrototypeに使用すべき ``FunctionType`` を作成します。Kaleidoscopeのすべての関数引数はdouble型であるため、最初の行は"N"個のLLVM double型のベクターを作成します。次に ``Functiontype::get`` メソッドを使用して、"N"個のdoubleを引数として受け取り、結果として1つのdoubleを返し、可変引数でない (falseパラメータがこれを示している) 関数型を作成します。LLVMの型は定数と同様に一意化されているため、型を"new"するのではなく"get"することに注意してください。

上記の最後の行は、実際にプロトタイプに対応するIR関数を作成します。これは使用する型、リンケージ、名前、および挿入するモジュールを示します。"`外部リンケージ <../../LangRef.html#linkage>`_" は、関数が現在のモジュールの外部で定義される可能性があり、かつ/またはモジュール外部の関数によって呼び出し可能であることを意味します。渡される名前はユーザーが指定した名前です: "``TheModule``"が指定されているため、この名前は"``TheModule``"のシンボルテーブルに登録されます。

.. code-block:: c++

  // すべての引数の名前を設定
  unsigned Idx = 0;
  for (auto &Arg : F->args())
    Arg.setName(Args[Idx++]);

  return F;

最後に、プロトタイプで指定された名前に従って、関数の各引数の名前を設定します。このステップは厳密には必要ありませんが、名前を一貫させることでIRがより読みやすくなり、後続のコードがプロトタイプASTで名前を調べる代わりに、引数を直接名前で参照できるようになります。

この時点で、本体のない関数プロトタイプができました。これは、LLVM IRが関数宣言を表現する方法です。Kaleidoscopeのextern文では、ここまでで十分です。しかし、関数定義の場合は、関数本体をコード生成して添付する必要があります。

.. code-block:: c++

  Function *FunctionAST::codegen() {
      // 最初に、以前の'extern'宣言からの既存の関数をチェック
    Function *TheFunction = TheModule->getFunction(Proto->getName());

    if (!TheFunction)
      TheFunction = Proto->codegen();

    if (!TheFunction)
      return nullptr;

    if (!TheFunction->empty())
      return (Function*)LogErrorV("Function cannot be redefined.");


関数定義では、'extern'文を使用してすでに作成されている場合に備えて、TheModuleのシンボルテーブルでこの関数の既存バージョンを検索することから始めます。Module::getFunctionがnullを返す場合は、以前のバージョンが存在しないため、プロトタイプから一つをコード生成します。いずれの場合も、開始前に関数が空である (つまり、まだ本体がない) ことをアサートしたいと思います。

.. code-block:: c++

  // 新しいベーシックブロックを作成して挿入を開始
  BasicBlock *BB = BasicBlock::Create(*TheContext, "entry", TheFunction);
  Builder->SetInsertPoint(BB);

  // 関数引数をNamedValuesマップに記録
  NamedValues.clear();
  for (auto &Arg : TheFunction->args())
    NamedValues[std::string(Arg.getName())] = &Arg;

ここで ``Builder`` が設定されるポイントに到達します。最初の行は新しい `ベーシックブロック <http://en.wikipedia.org/wiki/Basic_block>`_ ("エントリ"と名付けられた) を作成し、``TheFunction`` に挿入します。2行目は、新しい命令が新しいベーシックブロックの終わりに挿入されるべきであることをビルダーに伝えます。LLVMのベーシックブロックは、 `制御フローグラフ <http://en.wikipedia.org/wiki/Control_flow_graph>`_ を定義する関数の重要な部分です。制御フローがないため、現時点では関数には1つのブロックのみが含まれます。これは `第5章 <LangImpl05.html>`_ で修正します :)。

次に、関数引数をNamedValuesマップに追加し (まずクリアした後で)、``VariableExprAST`` ノードがアクセスできるようにします。

.. code-block:: c++

      if (Value *RetVal = Body->codegen()) {
        // 関数を完了させる
        Builder->CreateRet(RetVal);

        // 生成されたコードを検証し、一貫性をチェック
        verifyFunction(*TheFunction);

        return TheFunction;
      }

挿入ポイントが設定され、NamedValuesマップがポピュレートされた後、関数のルート式に対して ``codegen()`` メソッドを呼び出します。エラーが発生しなければ、これはエントリブロックに式を計算するコードを発行し、計算された値を返します。エラーがないと仮定して、関数を完成する LLVM `ret命令 <../../LangRef.html#ret-instruction>`_ を作成します。関数が構築されたら、LLVMが提供する ``verifyFunction`` を呼び出します。この関数は、コンパイラーがすべてを正しく実行しているかどうかを判定するため、生成されたコードに対してさまざまな一貫性チェックを実行します。これを使用することは重要です: 多くのバグを捕捉することができます。関数が完成し、検証されたら、それを返します。

.. code-block:: c++

      // 本体の読み取りエラー、関数を削除
      TheFunction->eraseFromParent();
      return nullptr;
    }

ここで残っている唯一の部分は、エラーケースの処理です。簡単にするため、 ``eraseFromParent`` メソッドで作成した関数を単に削除することでこれを処理します。これにより、ユーザーが以前に間違ってタイプした関数を再定義できます: これを削除しなければ、それは本体とともにシンボルテーブルに残り、将来の再定義を妨げてしまいます。

ただし、このコードにはバグがあります: ``FunctionAST::codegen()`` メソッドが既存のIR関数を見つけた場合、定義自身のプロトタイプに対してシグネチャを検証しません。これは、以前の'extern'宣言が関数定義のシグネチャよりも優先されることを意味し、たとえば関数引数の名前が違う場合にコード生成の失敗を引き起こす可能性があります。このバグを修正する方法はいくつかあります。どんな方法があるか考えてみてください！こちらがテストケースです: 

::

    extern foo(a);     # ok, fooを定義
    def foo(b) b;      # エラー: Unknown variable name. ('a'を使う宣言が優先される)

ドライバーの変更と結論
========================

現在のところ、LLVMへのコード生成は、美しいIR呼び出しを見ることができること以外は、実際にはそれほどの利益を得られません。サンプルコードは、"``HandleDefinition``"、"``HandleExtern``" などの関数にcodegenの呼び出しを挿入し、そしてLLVM IRをダンプ出力します。これにより、シンプルな関数のLLVM IRを見る良い方法を提供します。例えば: 

::

    ready> 4+5;
    トップレベル式を読み取り:
    define double @0() {
    entry:
      ret double 9.000000e+00
    }

parserがトップレベル式を無名関数に変換してくれることに注意してください。これは次の章で `JITサポート <LangImpl04.html#adding-a-jit-compiler>`_ を追加するときに便利になります。また、コードは非常に文字通りに転写され、IRBuilderが実行する単純な定数畳み込み以外は最適化が実行されていないことに注意してください。次の章では `最適化を明示的に追加 <LangImpl04.html#trivial-constant-folding>`_ します。

::

    ready> def foo(a b) a*a + 2*a*b + b*b;
    関数定義を読み取り:
    define double @foo(double %a, double %b) {
    entry:
      %multmp = fmul double %a, %a
      %multmp1 = fmul double 2.000000e+00, %a
      %multmp2 = fmul double %multmp1, %b
      %addtmp = fadd double %multmp, %multmp2
      %multmp3 = fmul double %b, %b
      %addtmp4 = fadd double %addtmp, %multmp3
      ret double %addtmp4
    }

これはシンプルな算術を示しています。命令を作成するために使用するLLVMビルダー呼び出しとの驚くべき類似性に注意してください。

::

    ready> def bar(a) foo(a, 4.0) + bar(31337);
    関数定義を読み取り:
    define double @bar(double %a) {
    entry:
      %calltmp = call double @foo(double %a, double 4.000000e+00)
      %calltmp1 = call double @bar(double 3.133700e+04)
      %addtmp = fadd double %calltmp, %calltmp1
      ret double %addtmp
    }

これは関数呼び出しを示しています。この関数を呼び出した場合、実行に時間がかかることに注意してください。将来、再帰を実際に便利にするために条件制御フローを追加する予定です :)。

::

    ready> extern cos(x);
    externを読み取り:
    declare double @cos(double)

    ready> cos(1.234);
    トップレベル式を読み取り:
    define double @1() {
    entry:
      %calltmp = call double @cos(double 1.234000e+00)
      ret double %calltmp
    }

これはlibmの"cos"関数のexternとその呼び出しを示しています。

.. TODO:: Abandon Pygments' horrible `llvm` lexer. It just totally gives up
   on highlighting this due to the first line.

::

    ready> ^D
    ; ModuleID = 'my cool jit'

    define double @0() {
    entry:
      %addtmp = fadd double 4.000000e+00, 5.000000e+00
      ret double %addtmp
    }

    define double @foo(double %a, double %b) {
    entry:
      %multmp = fmul double %a, %a
      %multmp1 = fmul double 2.000000e+00, %a
      %multmp2 = fmul double %multmp1, %b
      %addtmp = fadd double %multmp, %multmp2
      %multmp3 = fmul double %b, %b
      %addtmp4 = fadd double %addtmp, %multmp3
      ret double %addtmp4
    }

    define double @bar(double %a) {
    entry:
      %calltmp = call double @foo(double %a, double 4.000000e+00)
      %calltmp1 = call double @bar(double 3.133700e+04)
      %addtmp = fadd double %calltmp, %calltmp1
      ret double %addtmp
    }

    declare double @cos(double)

    define double @1() {
    entry:
      %calltmp = call double @cos(double 1.234000e+00)
      ret double %calltmp
    }

現在のデモを終了するとき (LinuxでCTRL+D、WindowsでCTRL+ZとENTERでEOFを送信) 、生成されたモジュール全体のIRがダンプされます。ここでは、すべての関数が相互に参照している全体像を見ることができます。

これでKaleidoscopeチュートリアルの第3章が完了しました。次に、実際にコードを実行できるように `JITコード生成とオプティマイザーサポートの追加 <LangImpl04.html>`_ について説明します！

全コードリスト
==============

こちらはLLVMコードジェネレーターで強化された、実行中の例の完全なコードリストです。これはLLVMライブラリを使用するため、リンクする必要があります。このために、 `llvm-config <https://llvm.org/cmds/llvm-config.html>`_ ツールを使用して、makefile/コマンドラインに使用するオプションを通知します: 

.. code-block:: bash

    # コンパイル
    clang++ -g -O3 toy.cpp `llvm-config --cxxflags --ldflags --system-libs --libs core` -o toy
    # 実行
    ./toy

コードはこちらです: 

.. literalinclude:: ../../../examples/Kaleidoscope/Chapter3/toy.cpp
   :language: c++

`次: JITとオプティマイザーサポートの追加 <LangImpl04.html>`_

