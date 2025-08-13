============================================================
Kaleidoscope: 言語の拡張: ユーザー定義演算子
============================================================

.. contents::
   :local:

第6章 はじめに
======================

「 `LLVMを使った言語実装 <index.html>`_」チュートリアルの第6章へようこそ。チュートリアルのこの時点で、かなり最小限でありながらも有用で、完全に機能する言語を持つようになりました。しかし、まだ1つの大きな問題があります。私たちの言語には多くの有用な演算子がありません (除算、論理否定、または小なり以外の比較すらありません)。

チュートリアルのこの章では、シンプルで美しいKaleidoscope言語にユーザー定義演算子を追加するという大胆な逸脱を行います。この逸脱により、ある意味ではシンプルで醜い言語になりますが、同時に強力な言語にもなります。独自の言語を作成することの素晴らしい点の1つは、何が良いか悪いかを決めることができることです。このチュートリアルでは、興味深い解析技法を示す方法としてこれを使用することが適切であると仮定します。

このチュートリアルの最後に、 `マンデルブロート集合をレンダリング <#kicking-the-tires>`_ するKaleidoscopeアプリケーションの例を実行します。これは、Kaleidoscopeとその機能セットで何を構築できるかの例を示しています。

ユーザー定義演算子: アイデア
================================

Kaleidoscopeに追加する「演算子オーバーロード」は、C++のような言語よりも一般的です。C++では、既存の演算子を再定義することしか許可されていません: 文法をプログラマティックに変更したり、新しい演算子を導入したり、優先順位レベルを変更したりすることはできません。この章では、この機能をKaleidoscopeに追加し、ユーザーがサポートされている演算子のセットを完成させることができるようにします。

このようなチュートリアルでユーザー定義演算子を取り上げる目的は、手書きparserを使用することの力と柔軟性を示すことです。これまで実装してきたparserは、文法のほとんどの部分に再帰下降を使用し、式には演算子優先順位解析を使用しています。詳細は `第2章 <LangImpl02.html>`_ を参照してください。演算子優先順位解析を使用することで、プログラマーが文法に新しい演算子を導入することを許可するのは非常に簡単です: 文法はJITの実行に伴って動的に拡張可能です。

追加する2つの具体的な機能は、プログラム可能な単項演算子 (現在、Kaleidoscopeには単項演算子がまったくありません) と二項演算子です。その例は次の通りです:

::

    # Logical unary not.
    def unary!(v)
      if v then
        0
      else
        1;

    # Define > with the same precedence as <.
    def binary> 10 (LHS RHS)
      RHS < LHS;

    # Binary "logical or", (note that it does not "short circuit")
    def binary| 5 (LHS RHS)
      if LHS then
        1
      else if RHS then
        1
      else
        0;

    # Define = with slightly lower precedence than relationals.
    def binary= 9 (LHS RHS)
      !(LHS < RHS | LHS > RHS);

多くの言語は、標準ランタイムライブラリを言語自体で実装できることを目指しています。Kaleidoscopeでは、言語の重要な部分をライブラリで実装できます！

これらの機能の実装を2つの部分に分けます: ユーザー定義二項演算子のサポートの実装と単項演算子の追加です。

ユーザー定義二項演算子
=============================

現在のフレームワークでは、ユーザー定義二項演算子のサポートを追加するのは非常に簡単です。まず、unary/binaryキーワードのサポートを追加します: 

.. code-block:: c++

    enum Token {
      ...
      // operators
      tok_binary = -11,
      tok_unary = -12
    };
    ...
    static int gettok() {
    ...
        if (IdentifierStr == "for")
          return tok_for;
        if (IdentifierStr == "in")
          return tok_in;
        if (IdentifierStr == "binary")
          return tok_binary;
        if (IdentifierStr == "unary")
          return tok_unary;
        return tok_identifier;

これは、 `前の章 <LangImpl05.html#lexer-extensions-for-if-then-else>`_ で行ったように、unaryとbinaryキーワードのlexerサポートを追加するだけです。現在のASTの優れた点の1つは、二項演算子をASCIIコードをオペコードとして使用することで完全に汎用化して表現していることです。拡張された演算子についても、この同じ表現を使用するため、新しいASTやparserのサポートは必要ありません。

一方、関数定義の「def binary\| 5」部分で、これらの新しい演算子の定義を表現できる必要があります。これまでの文法では、関数定義の「名前」は「prototype」プロダクションとして解析され、 ``PrototypeAST`` ASTノードに入ります。新しいユーザー定義演算子をプロトタイプとして表現するには、 ``PrototypeAST`` ASTノードを次のように拡張する必要があります:

.. code-block:: c++

    /// PrototypeAST - このクラスは関数の「プロトタイプ」を表し、
    /// 引数名とそれが演算子であるかどうかをキャプチャします
    class PrototypeAST {
      std::string Name;
      std::vector<std::string> Args;
      bool IsOperator;
      unsigned Precedence;  // 二項演算子の場合の優先順位

    public:
      PrototypeAST(const std::string &Name, std::vector<std::string> Args,
                   bool IsOperator = false, unsigned Prec = 0)
      : Name(Name), Args(std::move(Args)), IsOperator(IsOperator),
        Precedence(Prec) {}

      Function *codegen();
      const std::string &getName() const { return Name; }

      bool isUnaryOp() const { return IsOperator && Args.size() == 1; }
      bool isBinaryOp() const { return IsOperator && Args.size() == 2; }

      char getOperatorName() const {
        assert(isUnaryOp() || isBinaryOp());
        return Name[Name.size() - 1];
      }

      unsigned getBinaryPrecedence() const { return Precedence; }
    };

基本的に、プロトタイプの名前を知ることに加えて、それが演算子であったかどうか、もしそうなら、演算子がどの優先順位レベルにあるかを追跡します。優先順位は二項演算子にのみ使用されます (以下で見るように、単項演算子には適用されません)。ユーザー定義演算子のプロトタイプを表現する方法ができたので、それを解析する必要があります:

.. code-block:: c++

    /// prototype
    ///   ::= id '(' id* ')'
    ///   ::= binary LETTER number? (id, id)
    static std::unique_ptr<PrototypeAST> ParsePrototype() {
      std::string FnName;

      unsigned Kind = 0;  // 0 = identifier, 1 = unary, 2 = binary.
      unsigned BinaryPrecedence = 30;

      switch (CurTok) {
      default:
        return LogErrorP("Expected function name in prototype");
      case tok_identifier:
        FnName = IdentifierStr;
        Kind = 0;
        getNextToken();
        break;
      case tok_binary:
        getNextToken();
        if (!isascii(CurTok))
          return LogErrorP("Expected binary operator");
        FnName = "binary";
        FnName += (char)CurTok;
        Kind = 2;
        getNextToken();

        // 優先順位が存在する場合は読み取る
        if (CurTok == tok_number) {
          if (NumVal < 1 || NumVal > 100)
            return LogErrorP("Invalid precedence: must be 1..100");
          BinaryPrecedence = (unsigned)NumVal;
          getNextToken();
        }
        break;
      }

      if (CurTok != '(')
        return LogErrorP("Expected '(' in prototype");

      std::vector<std::string> ArgNames;
      while (getNextToken() == tok_identifier)
        ArgNames.push_back(IdentifierStr);
      if (CurTok != ')')
        return LogErrorP("Expected ')' in prototype");

      // 成功
      getNextToken();  // eat ')'.

      // 演算子のための名前の数が正しいことを確認
      if (Kind && ArgNames.size() != Kind)
        return LogErrorP("Invalid number of operands for operator");

      return std::make_unique<PrototypeAST>(FnName, std::move(ArgNames), Kind != 0,
                                             BinaryPrecedence);
    }

これはすべて非常に分かりやすい解析コードであり、過去に多くの類似コードをすでに見てきました。上記のコードの興味深い部分の1つは、二項演算子用の ``FnName`` を設定するいくつかの行です。これは、新しく定義された「@」演算子用に「binary@」のような名前を構築します。そして、LLVMシンボルテーブル内のシンボル名には、埋め込まれたnul文字を含む任意の文字を含めることができるという事実を利用しています。

次に追加する興味深いものは、これらの二項演算子のcodegenサポートです。現在の構造を考えると、これは既存の二項演算子ノード用のdefaultケースの単純な追加です: 

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
        break;
      }

      // もし組み込みの二項演算子でなければ、ユーザー定義のものであるはずなのでそれに対する呼び出しを生成
      Function *F = getFunction(std::string("binary") + Op);
      assert(F && "binary operator not found!");

      Value *Ops[2] = { L, R };
      return Builder->CreateCall(F, Ops, "binop");
    }

上記で見ることができるように、新しいコードは実際に非常にシンプルです。シンボルテーブルで適切な演算子を検索し、それに対する関数呼び出しを生成するだけです。ユーザー定義演算子は通常の関数として構築されるだけなので (「prototype」は適切な名前を持つ関数に要約されるため) 、すべてが適切に配置されます。

私たちが見落としているコードの最後の部分は、少しのトップレベルの魔法です: 

.. code-block:: c++

    Function *FunctionAST::codegen() {
      // プロトタイプの所有権をFunctionProtosマップに移すが、以下で使用するために参照を保持
      auto &P = *Proto;
      FunctionProtos[Proto->getName()] = std::move(Proto);
      Function *TheFunction = getFunction(P.getName());
      if (!TheFunction)
        return nullptr;

      // 演算子であればそれを登録
      if (P.isBinaryOp())
        BinopPrecedence[P.getOperatorName()] = P.getBinaryPrecedence();

      // 新しい基本ブロックを作成しそこに挿入を開始
      BasicBlock *BB = BasicBlock::Create(*TheContext, "entry", TheFunction);
      ...

基本的に、関数をコード生成する前に、それがユーザー定義演算子である場合、優先順位テーブルに登録します。これにより、すでに配置されている二項演算子解析ロジックがそれを処理できるようになります。完全に一般的な演算子優先順位parserを扱っているため、これは「文法を拡張する」ために必要なすべてです。

これで、有用なユーザー定義二項演算子ができました。これは、他の演算子用に構築した以前のフレームワークを大いに活用しています。単項演算子の追加は、まだそのフレームワークがないため、少し挑戦的です。何が必要かを見てみましょう。

ユーザー定義単項演算子
============================

現在Kaleidoscope言語では単項演算子をサポートしていないため、それらをサポートするためのすべてを追加する必要があります。上記で、lexerに'unary'キーワードの単純なサポートを追加しました。それに加えて、ASTノードが必要です: 

.. code-block:: c++

    /// UnaryExprAST - Expression class for a unary operator.
    class UnaryExprAST : public ExprAST {
      char Opcode;
      std::unique_ptr<ExprAST> Operand;

    public:
      UnaryExprAST(char Opcode, std::unique_ptr<ExprAST> Operand)
        : Opcode(Opcode), Operand(std::move(Operand)) {}

      Value *codegen() override;
    };

このASTノードは、現在では非常にシンプルで明白です。二項演算子ASTノードを直接反映しており、子が1つしかないことを除いて同じです。これで、解析ロジックを追加する必要があります。単項演算子の解析はかなり簡単です: それを行うための新しい関数を追加します: 

.. code-block:: c++

    /// unary
    ///   ::= primary
    ///   ::= '!' unary
    static std::unique_ptr<ExprAST> ParseUnary() {
      // 現在のトークンが演算子でない場合、それはプライマリ式である必要がある
      if (!isascii(CurTok) || CurTok == '(' || CurTok == ',')
        return ParsePrimary();

      // これが単項演算子である場合、それを読み取る
      int Opc = CurTok;
      getNextToken();
      if (auto Operand = ParseUnary())
        return std::make_unique<UnaryExprAST>(Opc, std::move(Operand));
      return nullptr;
    }

ここで追加する文法は非常に分かりやすいです。プライマリ演算子を解析する際に単項演算子を見つけた場合、演算子をプレフィックスとして消費し、残りの部分を別の単項演算子として解析します。これにより、複数の単項演算子 (例: 「!!x」) を処理できます。単項演算子は二項演算子のような曖昧な解析を持つことができないため、優先順位情報は必要ないことに注意してください。

この関数の問題は、どこかからParseUnaryを呼び出す必要があることです。これを行うために、ParsePrimaryの以前の呼び出し元を、代わりにParseUnaryを呼び出すように変更します: 

.. code-block:: c++

    /// binoprhs
    ///   ::= ('+' unary)*
    static std::unique_ptr<ExprAST> ParseBinOpRHS(int ExprPrec,
                                                  std::unique_ptr<ExprAST> LHS) {
      ...
        // 二項演算子の後の単項式を解析する
        auto RHS = ParseUnary();
        if (!RHS)
          return nullptr;
      ...
    }
    /// expression
    ///   ::= unary binoprhs
    ///
    static std::unique_ptr<ExprAST> ParseExpression() {
      auto LHS = ParseUnary();
      if (!LHS)
        return nullptr;

      return ParseBinOpRHS(0, std::move(LHS));
    }

これら2つの簡単な変更により、単項演算子を解析し、それらのASTを構築できるようになりました。次に、単項演算子プロトタイプを解析するためのプロトタイプのparserサポートを追加する必要があります。上記の二項演算子コードを次のように拡張します: 

.. code-block:: c++

    /// prototype
    ///   ::= id '(' id* ')'
    ///   ::= binary LETTER number? (id, id)
    ///   ::= unary LETTER (id)
    static std::unique_ptr<PrototypeAST> ParsePrototype() {
      std::string FnName;

      unsigned Kind = 0;  // 0 = identifier, 1 = unary, 2 = binary.
      unsigned BinaryPrecedence = 30;

      switch (CurTok) {
      default:
        return LogErrorP("Expected function name in prototype");
      case tok_identifier:
        FnName = IdentifierStr;
        Kind = 0;
        getNextToken();
        break;
      case tok_unary:
        getNextToken();
        if (!isascii(CurTok))
          return LogErrorP("Expected unary operator");
        FnName = "unary";
        FnName += (char)CurTok;
        Kind = 1;
        getNextToken();
        break;
      case tok_binary:
        ...

二項演算子と同様に、単項演算子には演算子文字を含む名前を付けます。これはコード生成時に役立ちます。そういえば、追加する必要がある最後の部分は、単項演算子のcodegenサポートです。これは次のようになります: 

.. code-block:: c++

    Value *UnaryExprAST::codegen() {
      Value *OperandV = Operand->codegen();
      if (!OperandV)
        return nullptr;

      Function *F = getFunction(std::string("unary") + Opcode);
      if (!F)
        return LogErrorV("Unknown unary operator");

      return Builder->CreateCall(F, OperandV, "unop");
    }

このコードは、二項演算子のコードと似ていますが、より簡単です。主に事前定義された演算子を処理する必要がないため、より簡単です。

動作確認
=================

いくらか信じがたいことですが、最後の数章で扱ったいくつかの簡単な拡張により、実際に近い言語を成長させました。これにより、I/O、数学、その他多くのことを含む多くの興味深いことができます。たとえば、素晴らしい順次演算子を追加できるようになりました (printdは指定された値と改行を印刷するように定義されています) : 

::

    ready> extern printd(x);
    Read extern:
    declare double @printd(double)

    ready> def binary : 1 (x y) 0;  # Low-precedence operator that ignores operands.
    ...
    ready> printd(123) : printd(456) : printd(789);
    123.000000
    456.000000
    789.000000
    Evaluated to 0.000000

他にも多くの「プリミティブ」操作を定義できます。例えば: 

::

    # Logical unary not.
    def unary!(v)
      if v then
        0
      else
        1;

    # Unary negate.
    def unary-(v)
      0-v;

    # Define > with the same precedence as <.
    def binary> 10 (LHS RHS)
      RHS < LHS;

    # Binary logical or, which does not short circuit.
    def binary| 5 (LHS RHS)
      if LHS then
        1
      else if RHS then
        1
      else
        0;

    # Binary logical and, which does not short circuit.
    def binary& 6 (LHS RHS)
      if !LHS then
        0
      else
        !!RHS;

    # Define = with slightly lower precedence than relationals.
    def binary = 9 (LHS RHS)
      !(LHS < RHS | LHS > RHS);

    # Define ':' for sequencing: as a low-precedence operator that ignores operands
    # and just returns the RHS.
    def binary : 1 (x y) y;

以前のif/then/elseサポートを考慮すると、I/O用の興味深い関数も定義できます。たとえば、次のものは渡された値を反映した「密度」の文字を印刷します: 値が低いほど、文字はより密になります: 

::

    ready> extern putchard(char);
    ...
    ready> def printdensity(d)
      if d > 8 then
        putchard(32)  # ' '
      else if d > 4 then
        putchard(46)  # '.'
      else if d > 2 then
        putchard(43)  # '+'
      else
        putchard(42); # '*'
    ...
    ready> printdensity(1): printdensity(2): printdensity(3):
           printdensity(4): printdensity(5): printdensity(9):
           putchard(10);
    **++.
    Evaluated to 0.000000

これらのシンプルなプリミティブ操作に基づいて、より興味深いものを定義し始めることができます。たとえば、複素平面内の特定の関数が発散するまでに必要な反復数を決定する小さな関数があります: 

::

    # Determine whether the specific location diverges.
    # Solve for z = z^2 + c in the complex plane.
    def mandelconverger(real imag iters creal cimag)
      if iters > 255 | (real*real + imag*imag > 4) then
        iters
      else
        mandelconverger(real*real - imag*imag + creal,
                        2*real*imag + cimag,
                        iters+1, creal, cimag);

    # Return the number of iterations required for the iteration to escape
    def mandelconverge(real imag)
      mandelconverger(real, imag, 0, real, imag);

この「 ``z = z^2 + c``」関数は、 `マンデルブロート集合 <http://en.wikipedia.org/wiki/Mandelbrot_set>`_ の計算の基礎となる美しい小さな生き物です。私たちの ``mandelconverge`` 関数は、複素軌道が脱出するのに必要な反復数を返し、255に飽和します。これは単体では非常に有用な関数ではありませんが、その値を2次元平面上にプロットすると、マンデルブロート集合を見ることができます。ここではputchardの使用に制限されているため、私たちの素晴らしいグラフィカル出力は制限されていますが、上記の密度プロッターを使って何かをまとめることができます:

::

    # Compute and plot the mandelbrot set with the specified 2 dimensional range
    # info.
    def mandelhelp(xmin xmax xstep   ymin ymax ystep)
      for y = ymin, y < ymax, ystep in (
        (for x = xmin, x < xmax, xstep in
           printdensity(mandelconverge(x,y)))
        : putchard(10)
      )

    # mandel - This is a convenient helper function for plotting the mandelbrot set
    # from the specified position with the specified Magnification.
    def mandel(realstart imagstart realmag imagmag)
      mandelhelp(realstart, realstart+realmag*78, realmag,
                 imagstart, imagstart+imagmag*40, imagmag);

これで、マンデルブロート集合をプロットしてみることができます！試してみましょう: 

::

    ready> mandel(-2.3, -1.3, 0.05, 0.07);
    *******************************+++++++++++*************************************
    *************************+++++++++++++++++++++++*******************************
    **********************+++++++++++++++++++++++++++++****************************
    *******************+++++++++++++++++++++.. ...++++++++*************************
    *****************++++++++++++++++++++++.... ...+++++++++***********************
    ***************+++++++++++++++++++++++.....   ...+++++++++*********************
    **************+++++++++++++++++++++++....     ....+++++++++********************
    *************++++++++++++++++++++++......      .....++++++++*******************
    ************+++++++++++++++++++++.......       .......+++++++******************
    ***********+++++++++++++++++++....                ... .+++++++*****************
    **********+++++++++++++++++.......                     .+++++++****************
    *********++++++++++++++...........                    ...+++++++***************
    ********++++++++++++............                      ...++++++++**************
    ********++++++++++... ..........                        .++++++++**************
    *******+++++++++.....                                   .+++++++++*************
    *******++++++++......                                  ..+++++++++*************
    *******++++++.......                                   ..+++++++++*************
    *******+++++......                                     ..+++++++++*************
    *******.... ....                                      ...+++++++++*************
    *******.... .                                         ...+++++++++*************
    *******+++++......                                    ...+++++++++*************
    *******++++++.......                                   ..+++++++++*************
    *******++++++++......                                   .+++++++++*************
    *******+++++++++.....                                  ..+++++++++*************
    ********++++++++++... ..........                        .++++++++**************
    ********++++++++++++............                      ...++++++++**************
    *********++++++++++++++..........                     ...+++++++***************
    **********++++++++++++++++........                     .+++++++****************
    **********++++++++++++++++++++....                ... ..+++++++****************
    ***********++++++++++++++++++++++.......       .......++++++++*****************
    ************+++++++++++++++++++++++......      ......++++++++******************
    **************+++++++++++++++++++++++....      ....++++++++********************
    ***************+++++++++++++++++++++++.....   ...+++++++++*********************
    *****************++++++++++++++++++++++....  ...++++++++***********************
    *******************+++++++++++++++++++++......++++++++*************************
    *********************++++++++++++++++++++++.++++++++***************************
    *************************+++++++++++++++++++++++*******************************
    ******************************+++++++++++++************************************
    *******************************************************************************
    *******************************************************************************
    *******************************************************************************
    Evaluated to 0.000000
    ready> mandel(-2, -1, 0.02, 0.04);
    **************************+++++++++++++++++++++++++++++++++++++++++++++++++++++
    ***********************++++++++++++++++++++++++++++++++++++++++++++++++++++++++
    *********************+++++++++++++++++++++++++++++++++++++++++++++++++++++++++.
    *******************+++++++++++++++++++++++++++++++++++++++++++++++++++++++++...
    *****************+++++++++++++++++++++++++++++++++++++++++++++++++++++++++.....
    ***************++++++++++++++++++++++++++++++++++++++++++++++++++++++++........
    **************++++++++++++++++++++++++++++++++++++++++++++++++++++++...........
    ************+++++++++++++++++++++++++++++++++++++++++++++++++++++..............
    ***********++++++++++++++++++++++++++++++++++++++++++++++++++........        .
    **********++++++++++++++++++++++++++++++++++++++++++++++.............
    ********+++++++++++++++++++++++++++++++++++++++++++..................
    *******+++++++++++++++++++++++++++++++++++++++.......................
    ******+++++++++++++++++++++++++++++++++++...........................
    *****++++++++++++++++++++++++++++++++............................
    *****++++++++++++++++++++++++++++...............................
    ****++++++++++++++++++++++++++......   .........................
    ***++++++++++++++++++++++++.........     ......    ...........
    ***++++++++++++++++++++++............
    **+++++++++++++++++++++..............
    **+++++++++++++++++++................
    *++++++++++++++++++.................
    *++++++++++++++++............ ...
    *++++++++++++++..............
    *+++....++++................
    *..........  ...........
    *
    *..........  ...........
    *+++....++++................
    *++++++++++++++..............
    *++++++++++++++++............ ...
    *++++++++++++++++++.................
    **+++++++++++++++++++................
    **+++++++++++++++++++++..............
    ***++++++++++++++++++++++............
    ***++++++++++++++++++++++++.........     ......    ...........
    ****++++++++++++++++++++++++++......   .........................
    *****++++++++++++++++++++++++++++...............................
    *****++++++++++++++++++++++++++++++++............................
    ******+++++++++++++++++++++++++++++++++++...........................
    *******+++++++++++++++++++++++++++++++++++++++.......................
    ********+++++++++++++++++++++++++++++++++++++++++++..................
    Evaluated to 0.000000
    ready> mandel(-0.9, -1.4, 0.02, 0.03);
    *******************************************************************************
    *******************************************************************************
    *******************************************************************************
    **********+++++++++++++++++++++************************************************
    *+++++++++++++++++++++++++++++++++++++++***************************************
    +++++++++++++++++++++++++++++++++++++++++++++**********************************
    ++++++++++++++++++++++++++++++++++++++++++++++++++*****************************
    ++++++++++++++++++++++++++++++++++++++++++++++++++++++*************************
    +++++++++++++++++++++++++++++++++++++++++++++++++++++++++**********************
    +++++++++++++++++++++++++++++++++.........++++++++++++++++++*******************
    +++++++++++++++++++++++++++++++....   ......+++++++++++++++++++****************
    +++++++++++++++++++++++++++++.......  ........+++++++++++++++++++**************
    ++++++++++++++++++++++++++++........   ........++++++++++++++++++++************
    +++++++++++++++++++++++++++.........     ..  ...+++++++++++++++++++++**********
    ++++++++++++++++++++++++++...........        ....++++++++++++++++++++++********
    ++++++++++++++++++++++++.............       .......++++++++++++++++++++++******
    +++++++++++++++++++++++.............        ........+++++++++++++++++++++++****
    ++++++++++++++++++++++...........           ..........++++++++++++++++++++++***
    ++++++++++++++++++++...........                .........++++++++++++++++++++++*
    ++++++++++++++++++............                  ...........++++++++++++++++++++
    ++++++++++++++++...............                 .............++++++++++++++++++
    ++++++++++++++.................                 ...............++++++++++++++++
    ++++++++++++..................                  .................++++++++++++++
    +++++++++..................                      .................+++++++++++++
    ++++++........        .                               .........  ..++++++++++++
    ++............                                         ......    ....++++++++++
    ..............                                                    ...++++++++++
    ..............                                                    ....+++++++++
    ..............                                                    .....++++++++
    .............                                                    ......++++++++
    ...........                                                     .......++++++++
    .........                                                       ........+++++++
    .........                                                       ........+++++++
    .........                                                           ....+++++++
    ........                                                             ...+++++++
    .......                                                              ...+++++++
                                                                        ....+++++++
                                                                       .....+++++++
                                                                        ....+++++++
                                                                        ....+++++++
                                                                        ....+++++++
    Evaluated to 0.000000
    ready> ^D

この時点で、Kaleidoscopeが実際の強力な言語であることを理解し始めているかもしれません。自己相似ではないかもしれませんが :) 、自己相似なものをプロットするために使用できます！

これで、チュートリアルの「ユーザー定義演算子の追加」章を終了します。私たちは言語を拡張することに成功し、ライブラリで言語を拡張する能力を追加し、これをどのようにしてKaleidoscopeでシンプルだが興味深いエンドユーザーアプリケーションを構築するために使用できるかを示しました。この時点で、Kaleidoscopeは機能的でありながら副作用のある関数を呼び出すことができるさまざまなアプリケーションを構築できますが、実際に変数自体を定義して変更することはできません。

驚くことに、変数変更は一部の言語の重要な機能であり、フロントエンドに「SSA構築」フェーズを追加することなく `可変変数のサポートを追加 <LangImpl07.html>`_ する方法は全く明白ではありません。次の章では、フロントエンドでSSAを構築することなく変数変更を追加する方法について説明します。

全コードリスト
=================

これは実行中の例の完全なコードリストで、ユーザー定義演算子のサポートで強化されています。この例をビルドするには、次を使用してください: 

.. code-block:: bash

    # コンパイル
    clang++ -g toy.cpp `llvm-config --cxxflags --ldflags --system-libs --libs core orcjit native` -O3 -o toy
    # 実行
    ./toy

一部のプラットフォームでは、リンク時に-rdynamicまたは-Wl,--export-dynamicを指定する必要があります。これにより、メイン実行ファイルで定義されたシンボルが動的リンカーにエクスポートされ、実行時のシンボル解決で利用できるようになります。サポートコードを共有ライブラリにコンパイルする場合はこれは必要ありませんが、そうするとWindowsで問題が発生します。

コードはこちらです: 

.. literalinclude:: ../../../examples/Kaleidoscope/Chapter6/toy.cpp
   :language: c++

`次: 言語の拡張: 可変変数 / SSA構築 <LangImpl07.html>`_

