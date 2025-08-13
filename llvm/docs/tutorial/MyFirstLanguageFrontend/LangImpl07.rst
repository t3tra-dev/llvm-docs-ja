=======================================================
Kaleidoscope: 言語の拡張: 可変変数
=======================================================

.. contents::
   :local:

第7章 はじめに
==============

「 `LLVMを使った言語実装 <index.html>`_」チュートリアルの第7章へようこそ。第1-6章では、シンプルながらも非常に立派な `関数型プログラミング言語 <http://en.wikipedia.org/wiki/Functional_programming>`_ を構築してきました。その過程で、解析技法、ASTの構築と表現方法、LLVM IRの構築、結果として生じるコードの最適化とJITコンパイルの方法を学びました。

Kaleidoscopeは関数型言語として興味深いものの、関数型であるという事実により、それに対するLLVM IRの生成が「過度に簡単」になっています。特に、関数型言語では、LLVM IRを直接 `SSA形式 <http://en.wikipedia.org/wiki/Static_single_assignment_form>`_ で構築することが非常に簡単です。LLVMでは入力コードがSSA形式であることが必要であるため、これは非常に良い性質ですが、可変変数を持つ命令型言語のコードを生成する方法は、初心者にとっては不明確なことがよくあります。

この章の短い (そして嬉しい) 要約は、フロントエンドがSSA形式を構築する必要はないということです: LLVMは、これに対して高度に調整されよくテストされたサポートを提供していますが、その動作方法は一部の人にとっては少し予期しないものです。

なぜこれは困難な問題なのか？
=============================

可変変数がSSA構築で複雑性を引き起こす理由を理解するため、この極めてシンプルなC言語の例を考えてみましょう: 

.. code-block:: c

    int G, H;
    int test(_Bool Condition) {
      int X;
      if (Condition)
        X = G;
      else
        X = H;
      return X;
    }

この場合、変数「X」の値は、プログラムで実行されるパスに依存します。return命令の前にXには2つの異なる可能な値があるため、PHIノードが2つの値をマージするために挿入されます。この例で求めるLLVM IRは次のようになります: 

.. code-block:: llvm

    @G = weak global i32 0   ; @Gの型はi32*
    @H = weak global i32 0   ; @Hの型はi32*

    define i32 @test(i1 %Condition) {
    entry:
      br i1 %Condition, label %cond_true, label %cond_false

    cond_true:
      %X.0 = load i32, i32* @G
      br label %cond_next

    cond_false:
      %X.1 = load i32, i32* @H
      br label %cond_next

    cond_next:
      %X.2 = phi i32 [ %X.1, %cond_false ], [ %X.0, %cond_true ]
      ret i32 %X.2
    }

この例では、GとHのグローバル変数からのロードはLLVM IR内で明示的であり、if文のthen/else分岐 (cond\_true/cond\_false) に存在します。入ってくる値をマージするため、cond\_nextブロック内のX.2 phiノードは、制御フローがどこから来るかに基づいて使用する正しい値を選択します: 制御フローがcond\_falseブロックから来る場合、X.2はX.1の値を取得します。一方、制御フローがcond\_trueから来る場合、X.0の値を取得します。この章の目的はSSA形式の詳細を説明することではありません。より詳しい情報については、多くの `オンライン参照 <http://en.wikipedia.org/wiki/Static_single_assignment_form>`_ の1つを参照してください。

この記事の疑問は「可変変数への代入を低レベル化する際に誰がphiノードを配置するのか？」ということです。ここでの問題は、LLVMはそのIRがSSA形式であることを*必須*としていることです: 「非ssa」モードは存在しません。しかし、SSA構築には自明でないアルゴリズムとデータ構造が必要であるため、すべてのフロントエンドがこのロジックを再実装しなければならないのは不便で無駄です。

LLVMにおけるメモリ
=================

ここでの「トリック」は、LLVMがすべてのレジスタ値にSSA形式であることを要求する一方で、メモリオブジェクトにSSA形式であることを要求しない (または許可しない) ことです。上記の例で、GとHからのロードがGとHへの直接アクセスであることに注目してください: それらはリネームされたりバージョン管理されたりしていません。これは、メモリオブジェクトのバージョン管理を試行する他の一部のコンパイラシステムとは異なります。LLVMでは、メモリのデータフロー解析をLLVM IRにエンコードする代わりに、オンデマンドで計算される `解析パス <../../WritingAnLLVMPass.html>`_ で処理されます。

これを踏まえて、高レベルのアイデアは、関数内の各可変オブジェクトに対してスタック変数 (スタック上にあるため、メモリ内に存在する) を作成したいということです。このトリックを活用するために、LLVMがスタック変数をどのように表現するかについて説明する必要があります。

LLVMでは、すべてのメモリアクセスがload/store命令で明示的であり、「address-of」演算子を持たない (または必要としない) ように慎重に設計されています。@G/@Hグローバル変数の型が、変数が「i32」として定義されているにもかかわらず、実際には「i32\*」であることに注目してください。これが意味するのは、@Gがグローバルデータ領域内でi32用の*スペース*を定義しているが、その*名前*は実際にはそのスペースのアドレスを参照しているということです。スタック変数も同じように動作しますが、グローバル変数定義で宣言される代わりに、 `LLVM alloca命令 <../../LangRef.html#alloca-instruction>`_ で宣言されます:

.. code-block:: llvm

    define i32 @example() {
    entry:
      %X = alloca i32           ; %Xの型はi32*
      ...
      %tmp = load i32, i32* %X  ; スタックから%Xのスタック値をロード
      %tmp2 = add i32 %tmp, 1   ; インクリメント
      store i32 %tmp2, i32* %X  ; スタックに戻してストア
      ...

このコードは、LLVM IR内でスタック変数を宣言および操作する方法の例を示しています。alloca命令で割り当てられたスタックメモリは完全に汎用的です: スタックスロットのアドレスを関数に渡すことができ、他の変数に格納することなどもできます。上記の例では、allocaテクニックを使用してPHIノードの使用を避けるように例を書き換えることができます: 

.. code-block:: llvm

    @G = weak global i32 0   ; @Gの型はi32*
    @H = weak global i32 0   ; @Hの型はi32*

    define i32 @test(i1 %Condition) {
    entry:
      %X = alloca i32           ; %Xの型はi32*
      br i1 %Condition, label %cond_true, label %cond_false

    cond_true:
      %X.0 = load i32, i32* @G
      store i32 %X.0, i32* %X   ; Xを更新
      br label %cond_next

    cond_false:
      %X.1 = load i32, i32* @H
      store i32 %X.1, i32* %X   ; Xを更新
      br label %cond_next

    cond_next:
      %X.2 = load i32, i32* %X  ; Xを読み取り
      ret i32 %X.2
    }

これにより、Phiノードを全く作成する必要なく、任意の可変変数を処理する方法を発見しました: 

#. 各可変変数はスタック割り当てになります。
#. 変数の各読み取りは、スタックからのロードになります。
#. 変数の各更新は、スタックへのストアになります。
#. 変数のアドレスを取ることは、単にスタックアドレスを直接使用します。

この解決策により直面していた問題は解決しましたが、別の問題を導入しました: 非常にシンプルで一般的な操作に対して、明らかに多くのスタックトラフィックを導入したことで、これは主要なパフォーマンス問題です。幸いなことに、LLVMオプティマイザーには「mem2reg」という高度に調整された最適化パスがあり、このケースを処理し、このようなallocaをSSAレジスタに昇格し、適切にPhiノードを挿入します。たとえば、この例をパスを通すと、次のようになります: 

.. code-block:: bash

    $ llvm-as < example.ll | opt -passes=mem2reg | llvm-dis
    @G = weak global i32 0
    @H = weak global i32 0

    define i32 @test(i1 %Condition) {
    entry:
      br i1 %Condition, label %cond_true, label %cond_false

    cond_true:
      %X.0 = load i32, i32* @G
      br label %cond_next

    cond_false:
      %X.1 = load i32, i32* @H
      br label %cond_next

    cond_next:
      %X.01 = phi i32 [ %X.1, %cond_false ], [ %X.0, %cond_true ]
      ret i32 %X.01
    }

mem2regパスは、SSA形式を構築するための標準的な「反復支配境界」アルゴリズムを実装し、 (非常に一般的な) 退化したケースを高速化する多くの最適化を持っています。mem2reg最適化パスは可変変数を扱う答えであり、これに依存することを強く推奨します。mem2regは特定の状況下でのみ変数に対して動作することに注意してください: 

#. mem2regはalloca主導です: allocaを探し、処理できる場合は昇格させます。グローバル変数やヒープ割り当てには適用されません。
#. mem2regは関数のエントリーブロック内のalloca命令のみを探します。エントリーブロック内にあることは、allocaが一度だけ実行されることを保証し、解析をより簡単にします。
#. mem2regは、直接的なロードとストアを使用するallocaのみを昇格させます。スタックオブジェクトのアドレスが関数に渡される場合、または何らかの奇妙なポインター演算が関与する場合、allocaは昇格されません。
#. mem2regは `第一級 <../../LangRef.html#first-class-types>`_ 値 (ポインター、スカラー、ベクトルなど) のallocaでのみ動作し、割り当ての配列サイズが1の場合 (または.llファイルで欠如している場合) のみです。mem2regは構造体や配列をレジスタに昇格させることはできません。「sroa」パスはより強力で、多くの場合に構造体、「共用体」、配列を昇格させることができることに注意してください。

これらの性質はすべて、ほとんどの命令型言語で満たすのが簡単で、以下でKaleidoscopeを使って説明します。最後に質問されるかもしれないのは: 私のフロントエンドでこのような無駄なことを気にする必要があるのでしょうか？mem2reg最適化パスの使用を避けて、直接SSA構築を行った方が良いのでは？簡潔に言うと、極めて良い理由がない限り、SSA形式を構築するためにこの技術を使用することを強く推奨します。この技術を使用することは:

- 実証済みでよくテストされている: clangはローカル可変変数に対してこの技術を使用します。そのため、LLVMの最も一般的なクライアントが変数の大部分を処理するためにこれを使用しています。バグが高速に発見され、早期に修正されることを確信できます。
- 極めて高速: mem2regには、一般的なケースで高速化し、完全に汎用的な多くの特殊ケースがあります。たとえば、単一ブロック内でのみ使用される変数、単一の代入ポイントのみを持つ変数、不要なphiノードの挿入を回避する良いヒューリスティックなどの高速パスがあります。
- デバッグ情報生成に必要: `LLVMのデバッグ情報 <../../SourceLevelDebugging.html>`_ は、デバッグ情報を添付できるように変数のアドレスが公開されることに依存しています。この技術は、このスタイルのデバッグ情報と非常に自然に調和します。

何よりも、これによりフロントエンドの立ち上げと実行がはるかに簡単になり、実装が非常にシンプルです。それでは、Kaleidoscopeを可変変数で拡張しましょう！

Kaleidoscopeにおける可変変数
============================

取り組みたい問題の種類が分かったので、小さなKaleidoscope言語のコンテキストでこれがどのように見えるかを見てみましょう。2つの機能を追加する予定です: 

#. '='演算子で変数を変更する能力。
#. 新しい変数を定義する能力。

最初の項目が本当にこれについて重要なことですが、現在変数は入力引数と帰納変数にのみ存在し、それらを再定義するだけではあまり意味がありません :) 。また、新しい変数を定義する能力は、それらを変更するかどうかに関係なく有用なものです。これらをどのように使用できるかを示す動機の例があります: 

::

    # シーケンス用の':'を定義: オペランドを無視して
    # 単にRHSを返す低優先順位の演算子として。
    def binary : 1 (x y) y;

    # 再帰フィボナッチ、以前からできた。
    def fib(x)
      if (x < 3) then
        1
      else
        fib(x-1)+fib(x-2);

    # 反復フィボナッチ。
    def fibi(x)
      var a = 1, b = 1, c in
      (for i = 3, i < x in
         c = a + b :
         a = b :
         b = c) :
      b;

    # 呼び出し。
    fibi(10);

変数を変更するには、既存の変数を「allocaトリック」を使用するように変更しなければなりません。それができたら、新しい演算子を追加し、その後Kaleidoscopeを拡張して新しい変数定義をサポートします。

変更のための既存変数の調整
========================

Kaleidoscopeのシンボルテーブルは、コード生成時に '``NamedValues``' マップによって管理されます。このマップは現在、名前付き変数のdouble値を保持するLLVM「Value\*」を追跡しています。変更をサポートするには、 ``NamedValues`` が問題の変数の*メモリ位置*を保持するように、これを少し変更する必要があります。この変更はリファクタリングであることに注意してください: コードの構造を変更しますが、 (それ自体では) コンパイラーの動作を変更しません。これらの変更はすべて、Kaleidoscopeコードジェネレーターに分離されています。

Kaleidoscopeの開発のこの時点では、2つのことについてのみ変数をサポートしています: 関数への入力引数と'for'ループの帰納変数。一貫性のために、他のユーザー定義変数に加えて、これらの変数の変更を許可します。これは、これらの両方がメモリ位置を必要とすることを意味します。

Kaleidoscopeの変換を開始するために、 ``NamedValues`` マップをValue\*の代わりにAllocaInst\*にマップするように変更します。これを行うと、C++コンパイラーがコードのどの部分を更新する必要があるかを教えてくれます:

.. code-block:: c++

    static std::map<std::string, AllocaInst*> NamedValues;

また、これらのallocaを作成する必要があるため、allocaが関数のエントリーブロック内で作成されることを保証するヘルパー関数を使用します: 

.. code-block:: c++

    /// CreateEntryBlockAlloca - 関数のエントリーブロック内でalloca命令を作成する。
    /// これは可変変数などに使用される。
    static AllocaInst *CreateEntryBlockAlloca(Function *TheFunction,
                                              StringRef VarName) {
      IRBuilder<> TmpB(&TheFunction->getEntryBlock(),
                     TheFunction->getEntryBlock().begin());
      return TmpB.CreateAlloca(Type::getDoubleTy(*TheContext), nullptr,
                               VarName);
    }

この奇妙に見えるコードは、エントリーブロックの最初の命令(.begin())を指すIRBuilderオブジェクトを作成します。次に、期待される名前でallocaを作成し、それを返します。Kaleidoscopeのすべての値はdoubleであるため、使用する型を渡す必要はありません。

これが配置されたことで、最初に行いたい機能変更は変数参照に属します。新しいスキームでは、変数はスタック上に存在するため、それらへの参照を生成するコードは実際にはスタックスロットからのロードを生成する必要があります:

.. code-block:: c++

    Value *VariableExprAST::codegen() {
      // 関数内でこの変数を検索する。
      AllocaInst *A = NamedValues[Name];
      if (!A)
        return LogErrorV("Unknown variable name");

      // 値をロードする。
      return Builder->CreateLoad(A->getAllocatedType(), A, Name.c_str());
    }

ご覧のとおり、これはかなり分かりやすいです。次に、変数を定義するものを更新してallocaを設定する必要があります。 ``ForExprAST::codegen()`` から始めます (省略されていないコードについては `完全なコードリスト <#id1>`_ を参照してください) :

.. code-block:: c++

      Function *TheFunction = Builder->GetInsertBlock()->getParent();

      // エントリーブロックで変数用のallocaを作成。
      AllocaInst *Alloca = CreateEntryBlockAlloca(TheFunction, VarName);

      // まず'variable'をスコープに入れずに開始コードを生成。
      Value *StartVal = Start->codegen();
      if (!StartVal)
        return nullptr;

      // allocaに値をストア。
      Builder->CreateStore(StartVal, Alloca);
      ...

      // 終了条件を計算。
      Value *EndCond = End->codegen();
      if (!EndCond)
        return nullptr;

      // allocaを再ロード、インクリメント、復元する。これはループの本体が
      // 変数を変更するケースを処理する。
      Value *CurVar = Builder->CreateLoad(Alloca->getAllocatedType(), Alloca,
                                          VarName.c_str());
      Value *NextVar = Builder->CreateFAdd(CurVar, StepVal, "nextvar");
      Builder->CreateStore(NextVar, Alloca);
      ...

このコードは、 `可変変数を許可する前のコード <LangImpl05.html#code-generation-for-the-for-loop>`_ とほぼ同一です。大きな違いは、もうPHIノードを構築する必要がなく、必要に応じてload/storeを使用して変数にアクセスすることです。

可変引数変数をサポートするには、それらに対してもallocaを作成する必要があります。これに対するコードもかなりシンプルです: 

.. code-block:: c++

    Function *FunctionAST::codegen() {
      ...
      Builder->SetInsertPoint(BB);

      // NamedValuesマップに関数引数を記録する。
      NamedValues.clear();
      for (auto &Arg : TheFunction->args()) {
        // この変数用のallocaを作成する。
        AllocaInst *Alloca = CreateEntryBlockAlloca(TheFunction, Arg.getName());

        // 初期値をallocaにストアする。
        Builder->CreateStore(&Arg, Alloca);

        // 変数シンボルテーブルに引数を追加する。
        NamedValues[std::string(Arg.getName())] = Alloca;
      }

      if (Value *RetVal = Body->codegen()) {
        ...

各引数について、allocaを作成し、関数への入力値をallocaにストアし、引数のメモリ位置としてallocaを登録します。このメソッドは、関数のエントリーブロックを設定した直後に ``FunctionAST::codegen()`` によって呼び出されます。

最後に欠けている部分は、mem2regパスを追加することで、再び良いコードジェンを取得できるようにします: 

.. code-block:: c++

        // allocaをレジスタに昇格する。
        TheFPM->addPass(PromotePass());
        // シンプルな「peephole」最適化とビット演算最適化を行う。
        TheFPM->addPass(InstCombinePass());
        // 式を再結合する。
        TheFPM->addPass(ReassociatePass());
        ...

mem2reg最適化が実行される前後でコードがどのように見えるかを見ることは興味深いです。たとえば、これは再帰フィボナッチ関数の最適化前/最適化後のコードです。最適化前: 

.. code-block:: llvm

    define double @fib(double %x) {
    entry:
      %x1 = alloca double
      store double %x, double* %x1
      %x2 = load double, double* %x1
      %cmptmp = fcmp ult double %x2, 3.000000e+00
      %booltmp = uitofp i1 %cmptmp to double
      %ifcond = fcmp one double %booltmp, 0.000000e+00
      br i1 %ifcond, label %then, label %else

    then:       ; preds = %entry
      br label %ifcont

    else:       ; preds = %entry
      %x3 = load double, double* %x1
      %subtmp = fsub double %x3, 1.000000e+00
      %calltmp = call double @fib(double %subtmp)
      %x4 = load double, double* %x1
      %subtmp5 = fsub double %x4, 2.000000e+00
      %calltmp6 = call double @fib(double %subtmp5)
      %addtmp = fadd double %calltmp, %calltmp6
      br label %ifcont

    ifcont:     ; preds = %else, %then
      %iftmp = phi double [ 1.000000e+00, %then ], [ %addtmp, %else ]
      ret double %iftmp
    }

ここには1つの変数 (入力引数のx) のみがありますが、使用している極めて単純なコード生成戦略を依然として見ることができます。エントリーブロックでは、allocaが作成され、初期入力値がその中にストアされます。変数への各参照はスタックからのリロードを行います。また、if/then/else式を変更しなかったため、依然としてPHIノードを挿入することに注意してください。それに対してallocaを作成することも可能ですが、実際にはPHIノードを作成する方が簡単なので、依然としてPHIを作成するだけです。

これがmem2regパス実行後のコードです: 

.. code-block:: llvm

    define double @fib(double %x) {
    entry:
      %cmptmp = fcmp ult double %x, 3.000000e+00
      %booltmp = uitofp i1 %cmptmp to double
      %ifcond = fcmp one double %booltmp, 0.000000e+00
      br i1 %ifcond, label %then, label %else

    then:
      br label %ifcont

    else:
      %subtmp = fsub double %x, 1.000000e+00
      %calltmp = call double @fib(double %subtmp)
      %subtmp5 = fsub double %x, 2.000000e+00
      %calltmp6 = call double @fib(double %subtmp5)
      %addtmp = fadd double %calltmp, %calltmp6
      br label %ifcont

    ifcont:     ; preds = %else, %then
      %iftmp = phi double [ 1.000000e+00, %then ], [ %addtmp, %else ]
      ret double %iftmp
    }

これは変数の再定義がないため、mem2regにとっては自明なケースです。これを示すポイントは、このような露骨な非効率性を挿入することについての懸念を和らげることです :) 。

残りのオプティマイザーが実行された後、次のようになります: 

.. code-block:: llvm

    define double @fib(double %x) {
    entry:
      %cmptmp = fcmp ult double %x, 3.000000e+00
      %booltmp = uitofp i1 %cmptmp to double
      %ifcond = fcmp ueq double %booltmp, 0.000000e+00
      br i1 %ifcond, label %else, label %ifcont

    else:
      %subtmp = fsub double %x, 1.000000e+00
      %calltmp = call double @fib(double %subtmp)
      %subtmp5 = fsub double %x, 2.000000e+00
      %calltmp6 = call double @fib(double %subtmp5)
      %addtmp = fadd double %calltmp, %calltmp6
      ret double %addtmp

    ifcont:
      ret double 1.000000e+00
    }

ここで、simplifycfgパスが'else'ブロックの終わりにreturn命令を複製することを決定したことが分かります。これにより、いくつかの分岐とPHIノードを削除することができました。

すべてのシンボルテーブル参照がスタック変数を使用するように更新されたので、代入演算子を追加します。

新しい代入演算子
===============

現在のフレームワークでは、新しい代入演算子を追加することは非常にシンプルです。他の二項演算子と同じように解析しますが、 (ユーザーが定義することを許可する代わりに) 内部で処理します。最初のステップは優先順位を設定することです: 

.. code-block:: c++

     int main() {
       // 標準的な二項演算子をインストール。
       // 1が最低優先順位。
       BinopPrecedence['='] = 2;
       BinopPrecedence['<'] = 10;
       BinopPrecedence['+'] = 20;
       BinopPrecedence['-'] = 20;

parserが二項演算子の優先順位を知ったので、すべての解析とAST生成を処理します。代入演算子のcodegenを実装するだけです。これは次のようになります: 

.. code-block:: c++

    Value *BinaryExprAST::codegen() {
      // LHSを式として生成したくないので'='を特別ケースとして処理
      if (Op == '=') {
        // LLVMがデフォルトでRTTIなしでビルドされるため、RTTIなしでビルドすることを仮定。
        // RTTIでLLVMをビルドする場合、これは自動エラーチェック用の
        // dynamic_castに変更できる。
        VariableExprAST *LHSE = static_cast<VariableExprAST*>(LHS.get());
        if (!LHSE)
          return LogErrorV("destination of '=' must be a variable");

他の二項演算子と異なり、代入演算子は「LHS生成、RHS生成、計算実行」モデルに従いません。そのため、他の二項演算子が処理される前に特別ケースとして処理されます。もう1つの奇妙な点は、LHSが変数である必要があることです。「(x+1) = expr」は無効です - 「x = expr」のようなもののみが許可されます。

.. code-block:: c++

        // RHSをcodegen。
        Value *Val = RHS->codegen();
        if (!Val)
          return nullptr;

        // 名前を検索。
        Value *Variable = NamedValues[LHSE->getName()];
        if (!Variable)
          return LogErrorV("Unknown variable name");

        Builder->CreateStore(Val, Variable);
        return Val;
      }
      ...

変数を取得したら、代入のcodegenは分かりやすいです: 代入のRHSを生成し、ストアを作成し、計算された値を返します。値を返すことで「X = (Y = Z)」のような連鎖代入が可能になります。

代入演算子ができたので、ループ変数と引数を変更できます。たとえば、次のようなコードを実行できるようになりました: 

::

    # doubleを印刷する関数。
    extern printd(x);

    # シーケンス用の':'を定義: オペランドを無視して
    # 単にRHSを返す低優先順位の演算子として。
    def binary : 1 (x y) y;

    def test(x)
      printd(x) :
      x = 4 :
      printd(x);

    test(123);

実行すると、この例は「123」と「4」を印刷し、実際に値を変更したことを示しています！よし、目標を正式に実装しました: これを動作させるには一般的なケースでSSA構築が必要です。しかし、本当に有用にするには、独自のローカル変数を定義する能力が欲しいので、次にこれを追加しましょう！

ユーザー定義ローカル変数
======================

var/inの追加は、Kaleidoscopeに対して行った他の拡張と同じです: lexer、parser、AST、コードジェネレータを拡張します。新しい'var/in'構造を追加する最初のステップは、lexerを拡張することです。以前と同じように、これはかなり自明で、コードは次のようになります: 

.. code-block:: c++

    enum Token {
      ...
      // var definition
      tok_var = -13
    ...
    }
    ...
    static int gettok() {
    ...
        if (IdentifierStr == "in")
          return tok_in;
        if (IdentifierStr == "binary")
          return tok_binary;
        if (IdentifierStr == "unary")
          return tok_unary;
        if (IdentifierStr == "var")
          return tok_var;
        return tok_identifier;
    ...

次のステップは、構築するASTノードを定義することです。var/inについては、次のようになります: 

.. code-block:: c++

    /// VarExprAST - var/in用の式クラス
    class VarExprAST : public ExprAST {
      std::vector<std::pair<std::string, std::unique_ptr<ExprAST>>> VarNames;
      std::unique_ptr<ExprAST> Body;

    public:
      VarExprAST(std::vector<std::pair<std::string, std::unique_ptr<ExprAST>>> VarNames,
                 std::unique_ptr<ExprAST> Body)
        : VarNames(std::move(VarNames)), Body(std::move(Body)) {}

      Value *codegen() override;
    };

var/inは名前のリストを一度に定義することを許可し、各名前はオプションで初期化値を持つことができます。そのため、この情報をVarNamesベクターに取り込みます。また、var/inは本体を持ち、この本体はvar/inによって定義された変数にアクセスすることが許可されています。

これが配置されたことで、parser部分を定義できます。最初に行うのは、プライマリ式として追加することです: 

.. code-block:: c++

    /// primary
    ///   ::= identifierexpr
    ///   ::= numberexpr
    ///   ::= parenexpr
    ///   ::= ifexpr
    ///   ::= forexpr
    ///   ::= varexpr
    static std::unique_ptr<ExprAST> ParsePrimary() {
      switch (CurTok) {
      default:
        return LogError("unknown token when expecting an expression");
      case tok_identifier:
        return ParseIdentifierExpr();
      case tok_number:
        return ParseNumberExpr();
      case '(':
        return ParseParenExpr();
      case tok_if:
        return ParseIfExpr();
      case tok_for:
        return ParseForExpr();
      case tok_var:
        return ParseVarExpr();
      }
    }

次に ParseVarExpr を定義します: 

.. code-block:: c++

    /// varexpr ::= 'var' identifier ('=' expression)?
    //                    (',' identifier ('=' expression)?)* 'in' expression
    static std::unique_ptr<ExprAST> ParseVarExpr() {
      getNextToken();  // varを消費。

      std::vector<std::pair<std::string, std::unique_ptr<ExprAST>>> VarNames;

      // 少なくとも1つの変数名が必要。
      if (CurTok != tok_identifier)
        return LogError("expected identifier after var");

このコードの最初の部分は、identifier/exprペアのリストをローカルの ``VarNames`` ベクターに解析します。

.. code-block:: c++

      while (true) {
        std::string Name = IdentifierStr;
        getNextToken();  // identifierを消費。

        // オプションの初期化子を読み取り。
        std::unique_ptr<ExprAST> Init;
        if (CurTok == '=') {
          getNextToken(); // '='を消費。

          Init = ParseExpression();
          if (!Init) return nullptr;
        }

        VarNames.push_back(std::make_pair(Name, std::move(Init)));

        // varリストの終わり、ループを終了。
        if (CurTok != ',') break;
        getNextToken(); // ','を消費。

        if (CurTok != tok_identifier)
          return LogError("expected identifier list after var");
      }

すべての変数が解析されたら、本体を解析してASTノードを作成します: 

.. code-block:: c++

      // この時点で、'in'がなければならない。
      if (CurTok != tok_in)
        return LogError("expected 'in' keyword after 'var'");
      getNextToken();  // 'in'を消費。

      auto Body = ParseExpression();
      if (!Body)
        return nullptr;

      return std::make_unique<VarExprAST>(std::move(VarNames),
                                           std::move(Body));
    }

コードを解析して表現できるようになったので、それに対するLLVM IRの生成をサポートする必要があります。このコードは次のように始まります: 

.. code-block:: c++

    Value *VarExprAST::codegen() {
      std::vector<AllocaInst *> OldBindings;

      Function *TheFunction = Builder->GetInsertBlock()->getParent();

      // すべての変数を登録し、その初期化子を生成。
      for (unsigned i = 0, e = VarNames.size(); i != e; ++i) {
        const std::string &VarName = VarNames[i].first;
        ExprAST *Init = VarNames[i].second.get();

基本的に、すべての変数をループし、一度に1つずつインストールします。シンボルテーブルに入れる各変数について、OldBindingsで置き換える以前の値を記憶します。

.. code-block:: c++

        // 変数をスコープに追加する前に初期化子を生成、これにより
        // 初期化子が変数自身を参照することを防ぎ、次のような
        // ことを許可する: 
        //  var a = 1 in
        //    var a = a in ...   # 外側の'a'を参照
        Value *InitVal;
        if (Init) {
          InitVal = Init->codegen();
          if (!InitVal)
            return nullptr;
        } else { // 指定されない場合は0.0を使用。
          InitVal = ConstantFP::get(*TheContext, APFloat(0.0));
        }

        AllocaInst *Alloca = CreateEntryBlockAlloca(TheFunction, VarName);
        Builder->CreateStore(InitVal, Alloca);

        // 再帰から戻るときにバインディングを復元できるように
        // 古い変数バインディングを記憶。
        OldBindings.push_back(NamedValues[VarName]);

        // このバインディングを記憶。
        NamedValues[VarName] = Alloca;
      }

ここにはコードよりもコメントが多くあります。基本的なアイデアは、初期化子を生成し、allocaを作成し、それを指すようにシンボルテーブルを更新することです。すべての変数がシンボルテーブルにインストールされたら、var/in式の本体を評価します: 

.. code-block:: c++

      // すべての変数がスコープ内になったので、本体をcodegen。
      Value *BodyVal = Body->codegen();
      if (!BodyVal)
        return nullptr;

最後に、戻る前に、以前の変数バインディングを復元します: 

.. code-block:: c++

      // スコープからすべての変数をポップ。
      for (unsigned i = 0, e = VarNames.size(); i != e; ++i)
        NamedValues[VarNames[i].first] = OldBindings[i];

      // 本体の計算を返す。
      return BodyVal;
    }

すべてのこれの最終結果は、適切にスコープされた変数定義を取得し、さらに (自明に) それらの変更を許可することです :) 。

これで、設定した目標を達成しました。導入部からの素晴らしい反復fib例はコンパイルされ、うまく実行されます。mem2regパスは、すべてのスタック変数をSSAレジスタに最適化し、必要に応じてPHIノードを挿入し、フロントエンドはシンプルのまま: 「反復支配境界」計算はどこにも見当たりません。

完全なコードリスト
================

可変変数とvar/inサポートで強化されたランニング例の完全なコードリストです。この例をビルドするには、次を使用してください: 

.. code-block:: bash

    # コンパイル
    clang++ -g toy.cpp `llvm-config --cxxflags --ldflags --system-libs --libs core orcjit native` -O3 -o toy
    # 実行
    ./toy

コードはこちらです: 

.. literalinclude:: ../../../examples/Kaleidoscope/Chapter7/toy.cpp
   :language: c++

`次: オブジェクトコードへのコンパイル <LangImpl08.html>`_

