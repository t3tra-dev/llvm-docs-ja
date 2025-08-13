========================================
Kaleidoscope: ParserとASTの実装
========================================

.. contents::
   :local:

第2章 はじめに
===============

「 `LLVMを使った言語実装 <index.html>`_」チュートリアルの第2章へようこそ。この章では、 `第1章 <LangImpl01.html>`_ で構築したlexerを使用して、Kaleidoscope言語用の完全な `parser <http://en.wikipedia.org/wiki/Parsing>`_ を構築する方法を示します。parserができたら、 `抽象構文木 <http://en.wikipedia.org/wiki/Abstract_syntax_tree>`_ (AST) を定義して構築します。

これから構築するparserは、 `再帰下降解析 <http://en.wikipedia.org/wiki/Recursive_descent_parser>`_ と `演算子優先順位解析 <http://en.wikipedia.org/wiki/Operator-precedence_parser>`_ の組み合わせを使用してKaleidoscope言語を解析します (後者は二項式用、前者はそれ以外のすべて用) 。ただし、解析に入る前に、parserの出力である抽象構文木についてお話ししましょう。

抽象構文木 (AST) 
================

プログラムのASTは、コンパイラーの後の段階 (コード生成など) が解釈しやすい方法でその動作を捉えます。基本的に、言語内の各構造に対して1つのオブジェクトが欲しく、ASTは言語を密接にモデル化する必要があります。Kaleidoscopeでは、式、プロトタイプ、関数オブジェクトがあります。まず式から始めましょう: 

.. code-block:: c++

    /// ExprAST - すべての式ノードのベースクラス
    class ExprAST {
    public:
      virtual ~ExprAST() = default;
    };

    /// NumberExprAST - "1.0"のような数値リテラル用の式クラス
    class NumberExprAST : public ExprAST {
      double Val;

    public:
      NumberExprAST(double Val) : Val(Val) {}
    };

上記のコードは、基本ExprASTクラスと、数値リテラルに使用する1つのサブクラスの定義を示しています。このコードで重要な点は、NumberExprASTクラスがリテラルの数値をインスタンス変数として取得することです。これにより、コンパイラーの後の段階で格納された数値が何であるかを知ることができます。

現在はASTを作成するだけなので、有用なアクセサーメソッドはありません。例えば、コードをきれいに印刷する仮想メソッドを追加するのは非常に簡単でしょう。基本的な形のKaleidoscope言語で使用するその他の式ASTノード定義は次のとおりです: 

.. code-block:: c++

    /// VariableExprAST - "a"のような変数参照用の式クラス
    class VariableExprAST : public ExprAST {
      std::string Name;

    public:
      VariableExprAST(const std::string &Name) : Name(Name) {}
    };

    /// BinaryExprAST - 二項演算子用の式クラス
    class BinaryExprAST : public ExprAST {
      char Op;
      std::unique_ptr<ExprAST> LHS, RHS;

    public:
      BinaryExprAST(char Op, std::unique_ptr<ExprAST> LHS,
                    std::unique_ptr<ExprAST> RHS)
        : Op(Op), LHS(std::move(LHS)), RHS(std::move(RHS)) {}
    };

    /// CallExprAST - 関数呼び出し用の式クラス
    class CallExprAST : public ExprAST {
      std::string Callee;
      std::vector<std::unique_ptr<ExprAST>> Args;

    public:
      CallExprAST(const std::string &Callee,
                  std::vector<std::unique_ptr<ExprAST>> Args)
        : Callee(Callee), Args(std::move(Args)) {}
    };

これはすべて (意図的に) 非常に分かりやすくなっています: 変数は変数名を取得し、二項演算子は演算コード (「+」など) を取得し、呼び出しは関数名と任意の引数式のリストを取得します。私たちのASTの良い点の1つは、言語の構文について話すことなく言語機能を捉えることです。二項演算子の優先順位、字句構造などについての議論がないことに注意してください。

基本言語の場合、これらが定義するすべての式ノードです。条件制御フローがないため、チューリング完全ではありません。これは後の回で修正します。次に必要なのは、関数へのインターフェースについて話す方法と、関数自体について話す方法です: 

.. code-block:: c++

    /// PrototypeAST - 関数の「プロトタイプ」を表すクラス
    /// 関数の名前と引数名を捉える (つまり暗黙的に関数が取る引数の数) 
    class PrototypeAST {
      std::string Name;
      std::vector<std::string> Args;

    public:
      PrototypeAST(const std::string &Name, std::vector<std::string> Args)
        : Name(Name), Args(std::move(Args)) {}

      const std::string &getName() const { return Name; }
    };

    /// FunctionAST - 関数定義自体を表すクラス
    class FunctionAST {
      std::unique_ptr<PrototypeAST> Proto;
      std::unique_ptr<ExprAST> Body;

    public:
      FunctionAST(std::unique_ptr<PrototypeAST> Proto,
                  std::unique_ptr<ExprAST> Body)
        : Proto(std::move(Proto)), Body(std::move(Body)) {}
    };

Kaleidoscopeでは、関数は引数の数だけで型付けされます。すべての値が倍精度浮動小数点であるため、各引数の型をどこかに格納する必要はありません。より積極的で現実的な言語では、「ExprAST」クラスにはおそらく型フィールドがあるでしょう。

この足場があれば、Kaleidoscopeでの式と関数本体の解析について話すことができます。

Parserの基本
=============

構築するASTができたので、それを構築するparserコードを定義する必要があります。ここでのアイデアは、「x+y」のようなもの (lexerによって3つのトークンとして返される) を、次のような呼び出しで生成できるASTに解析することです: 

.. code-block:: c++

      auto LHS = std::make_unique<VariableExprAST>("x");
      auto RHS = std::make_unique<VariableExprAST>("y");
      auto Result = std::make_unique<BinaryExprAST>('+', std::move(LHS),
                                                    std::move(RHS));

これを行うために、いくつかの基本的なヘルパールーチンを定義することから始めます: 

.. code-block:: c++

    /// CurTok/getNextToken - 簡単なトークンバッファーを提供。CurTokは
    /// parserが見ている現在のトークン。getNextTokenはlexerから別のトークンを
    /// 読み取り、その結果でCurTokを更新する
    static int CurTok;
    static int getNextToken() {
      return CurTok = gettok();
    }

これは、lexerの周りに単純なトークンバッファーを実装します。これにより、lexerが返すものを1トークン先読みできます。parserのすべての関数は、CurTokが解析する必要がある現在のトークンであると想定します。

.. code-block:: c++


    /// LogError* - エラー処理用の小さなヘルパー関数
    std::unique_ptr<ExprAST> LogError(const char *Str) {
      fprintf(stderr, "Error: %s\n", Str);
      return nullptr;
    }
    std::unique_ptr<PrototypeAST> LogErrorP(const char *Str) {
      LogError(Str);
      return nullptr;
    }

``LogError`` ルーチンは、parserがエラーを処理するために使用する単純なヘルパールーチンです。parserのエラー回復は最良ではなく、特にユーザーフレンドリーではありませんが、このチュートリアルには十分です。これらのルーチンは、さまざまな戻り値の型を持つルーチンでエラーを処理しやすくします: 常にnullを返します。

これらの基本ヘルパー関数があれば、文法の最初の部分である数値リテラルを実装できます。

基本式解析
==========

最も処理が簡単なので、数値リテラルから始めます。文法の各生成規則について、その生成規則を解析する関数を定義します。数値リテラルの場合: 

.. code-block:: c++

    /// numberexpr ::= number
    static std::unique_ptr<ExprAST> ParseNumberExpr() {
      auto Result = std::make_unique<NumberExprAST>(NumVal);
      getNextToken(); // 数値を消費
      return std::move(Result);
    }

このルーチンは非常にシンプルです: 現在のトークンが ``tok_number`` トークンの場合に呼び出されることを期待しています。現在の数値を取得し、``NumberExprAST`` ノードを作成し、lexerを次のトークンに進め、最後に返します。

これにはいくつかの興味深い側面があります。最も重要なのは、このルーチンが生成規則に対応するすべてのトークンを消費し、次のトークン (文法生成規則の一部ではない) を準備してlexerバッファーを返すことです。これは再帰下降parserの非常に標準的な方法です。より良い例として、括弧演算子は次のように定義されます: 

.. code-block:: c++

    /// parenexpr ::= '(' expression ')'
    static std::unique_ptr<ExprAST> ParseParenExpr() {
      getNextToken(); // eat (.
      auto V = ParseExpression();
      if (!V)
        return nullptr;

      if (CurTok != ')')
        return LogError("expected ')'");
      getNextToken(); // eat ).
      return V;
    }

この関数は、parserについて多くの興味深いことを示しています: 

1) LogErrorルーチンの使用方法を示しています。呼び出されたとき、この関数は現在のトークンが'('トークンであることを期待していますが、部分式を解析した後、')'が待っていない可能性があります。例えば、ユーザーが"(4)"の代わりに"(4 x"と入力した場合、parserはエラーを発生させるべきです。エラーが発生する可能性があるため、parserはそれが起こったことを示す方法が必要です: 私たちのparserでは、エラー時にnullを返します。

2) この関数のもう1つの興味深い側面は、``ParseExpression`` を呼び出すことで再帰を使用することです (``ParseExpression`` が ``ParseParenExpr`` を呼び出すことができることをすぐに見るでしょう) 。これは強力で、再帰文法を処理でき、各生成規則を非常にシンプルに保てます。括弧自体はASTノードの構築を引き起こさないことに注意してください。このように行うこともできますが、括弧の最も重要な役割はparserをガイドしてグループ化を提供することです。parserがASTを構築すると、括弧は不要になります。

次の簡単な生成規則は、変数参照と関数呼び出しを処理するためのものです: 

.. code-block:: c++

    /// identifierexpr
    ///   ::= identifier
    ///   ::= identifier '(' expression* ')'
    static std::unique_ptr<ExprAST> ParseIdentifierExpr() {
      std::string IdName = IdentifierStr;

      getNextToken();  // eat identifier.

      if (CurTok != '(') // Simple variable ref.
        return std::make_unique<VariableExprAST>(IdName);

      // Call.
      getNextToken();  // eat (
      std::vector<std::unique_ptr<ExprAST>> Args;
      if (CurTok != ')') {
        while (true) {
          if (auto Arg = ParseExpression())
            Args.push_back(std::move(Arg));
          else
            return nullptr;

          if (CurTok == ')')
            break;

          if (CurTok != ',')
            return LogError("Expected ')' or ',' in argument list");
          getNextToken();
        }
      }

      // Eat the ')'.
      getNextToken();

      return std::make_unique<CallExprAST>(IdName, std::move(Args));
    }

このルーチンは他のルーチンと同じスタイルに従っています (現在のトークンが ``tok_identifier`` トークンの場合に呼び出されることを期待します) 。また、再帰とエラー処理も持っています。これの興味深い側面の1つは、 *先読み*を使用して、現在の識別子が独立した変数参照なのか、関数呼び出し式なのかを判断することです。識別子の後のトークンが'('トークンかどうかをチェックすることでこれを処理し、適切に ``VariableExprAST`` または ``CallExprAST`` ノードを構築します。

すべての単純な式解析ロジックが揃ったので、それらを1つのエントリーポイントにまとめるヘルパー関数を定義できます。この種類の式を「primary」式と呼びますが、その理由は `チュートリアルの後の方 <LangImpl06.html#user-defined-unary-operators>`_ でより明確になります。任意のprimary式を解析するには、それがどのような式かを判断する必要があります: 

.. code-block:: c++

    /// primary
    ///   ::= identifierexpr
    ///   ::= numberexpr
    ///   ::= parenexpr
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
      }
    }

この関数の定義を見れば、なぜ様々な関数でCurTokの状態を前提とできるかがより明白になります。これは先読みを使用してどの種類の式が検査されているかを判断し、関数呼び出しで解析します。

基本的な式が処理できるようになったので、二項式を処理する必要があります。これらは少し複雑です。

二項式解析
==========

二項式は曖昧な場合が多いため、解析が著しく困難です。例えば、文字列「x+y\*z」が与えられたとき、parserは「(x+y)\*z」または「x+(y\*z)」のいずれかとして解析することを選択できます。数学の一般的な定義により、「\*」 (乗算) は「+」 (加算) よりも高い*優先順位*を持つため、後者の解析を期待します。

これを処理する方法はたくさんありますが、エレガントで効率的な方法は `演算子優先順位解析 <http://en.wikipedia.org/wiki/Operator-precedence_parser>`_ を使用することです。この解析手法は、二項演算子の優先順位を使用して再帰をガイドします。まずは、優先順位のテーブルが必要です: 

.. code-block:: c++

    /// BinopPrecedence - 定義された各二項演算子の優先順位を保持する
    static std::map<char, int> BinopPrecedence;

    /// GetTokPrecedence - 保留中の二項演算子トークンの優先順位を取得
    static int GetTokPrecedence() {
      if (!isascii(CurTok))
        return -1;

      // 宣言された二項演算子かどうか確認
      int TokPrec = BinopPrecedence[CurTok];
      if (TokPrec <= 0) return -1;
      return TokPrec;
    }

    int main() {
      // 標準二項演算子をインストール
      // 1が最低優先順位
      BinopPrecedence['<'] = 10;
      BinopPrecedence['+'] = 20;
      BinopPrecedence['-'] = 20;
      BinopPrecedence['*'] = 40;  // 最高
      ...
    }

Kaleidoscopeの基本形では、4つの二項演算子のみをサポートします (これは、勇敢で不屈の読者の皆さんによって明らかに拡張できます) 。 ``GetTokPrecedence`` 関数は、現在のトークンの優先順位を返し、トークンが二項演算子でない場合は-1を返します。マップを持つことで、新しい演算子を簡単に追加でき、アルゴリズムが関与する特定の演算子に依存しないことが明確になりますが、マップを除去して ``GetTokPrecedence`` 関数で比較を行うことも十分簡単です (または、固定サイズ配列を使用するだけでも) 。

上記のヘルパーが定義されたことで、二項式の解析を始めることができます。演算子優先順位解析の基本アイデアは、曖昧になりうる二項演算子を持つ式をピースに分解することです。例えば、式"a+b+(c+d)\*e\*f+g"を考えてみてください。演算子優先順位解析は、これを二項演算子で区切られたプライマリ式のストリームとして考えます。そのため、まず先頭のプライマリ式"a"を解析し、次にペア[+, b] [+, (c+d)] [\*, e] [\*, f] および [+, g]を見ることになります。括弧はプライマリ式であるため、二項式パーサーは(c+d)のようなネストした部分式をまったく心配する必要がありません。

まず、式はプライマリ式であり、その後に[binop,primaryexpr]ペアのシーケンスが続く場合があります: 

.. code-block:: c++

    /// expression
    ///   ::= primary binoprhs
    ///
    static std::unique_ptr<ExprAST> ParseExpression() {
      auto LHS = ParsePrimary();
      if (!LHS)
        return nullptr;

      return ParseBinOpRHS(0, std::move(LHS));
    }

``ParseBinOpRHS`` は、私たちのためにペアのシーケンスを解析する関数です。これは優先順位と、これまでに解析された部分の式へのポインタを受け取ります。"x"は完全に有効な式であることに注意してください: そのため、"binoprhs"は空であることが許され、その場合には渡された式を返します。上記の例では、コードは"a"の式を ``ParseBinOpRHS`` に渡し、現在のトークンは"+"です。

``ParseBinOpRHS`` に渡される優先順位値は、関数が消費できる *最小演算子優先順位*を示します。例えば、現在のペアストリームが[+, x]で、 ``ParseBinOpRHS`` に優先順位40が渡された場合、トークンは消費されません (「+」の優先順位はわずか20だからです) 。これを念頭に置いて、``ParseBinOpRHS`` は次のように始まります: 

.. code-block:: c++

    /// binoprhs
    ///   ::= ('+' primary)*
    static std::unique_ptr<ExprAST> ParseBinOpRHS(int ExprPrec,
                                                  std::unique_ptr<ExprAST> LHS) {
      // 二項演算子の場合、その優先順位を見つける
      while (true) {
        int TokPrec = GetTokPrecedence();

        // 現在の二項演算子と同じかそれ以上に強く結合する二項演算子の場合、消費する。
        // そうでなければ完了
        if (TokPrec < ExprPrec)
          return LHS;

このコードは現在のトークンの優先順位を取得し、それが低すぎるかどうかをチェックします。無効なトークンの優先順位を-1と定義したため、このチェックは、トークンストリームが二項演算子を使い果たしたときにペアストリームが終了することを暗黙的に知っています。このチェックが成功した場合、トークンが二項演算子であり、この式に含まれることがわかります: 

.. code-block:: c++

        // これが二項演算子であることがわかった
        int BinOp = CurTok;
        getNextToken();  // 二項演算子を消費

        // 二項演算子の後のプライマリ式を解析
        auto RHS = ParsePrimary();
        if (!RHS)
          return nullptr;

このように、このコードは二項演算子を消費 (そして記憶) してから、それに続くプライマリ式を解析します。これによって全体のペアが構築され、実行例の最初のペアは[+, b]になります。

式の左辺と右辺シーケンスの1つのペアを解析したので、式がどちらの方向に結合するかを決定しなければなりません。特に、「(a+b) binop unparsed」または「a + (b binop unparsed)」を持つことができます。これを決定するために、「binop」を先読みしてその優先順位を決定し、BinOpの優先順位 (この場合は「+」) と比較します: 

.. code-block:: c++

        // BinOpがRHS以降の演算子よりも弱く結合する場合、
        // 保留中の演算子がRHSをそのLHSとして取るようにする
        int NextPrec = GetTokPrecedence();
        if (TokPrec < NextPrec) {

「RHS」の右側にある二項演算子の優先順位が現在の演算子の優先順位よりも低いか等しい場合、括弧は「(a+b) binop ...」として結合することがわかります。この例では、現在の演算子は「+」で次の演算子は「+」であり、それらは同じ優先順位を持つことがわかります。この場合、「a+b」のASTノードを作成し、解析を続行します: 

.. code-block:: c++

          ... if body省略 ...
        }

        // LHS/RHSをマージ
        LHS = std::make_unique<BinaryExprAST>(BinOp, std::move(LHS),
                                               std::move(RHS));
      }  // whileループの先頭に戻る
    }

上記の例では、これにより「a+b+」が「(a+b)」に変換され、「+」を現在のトークンとしてループの次の反復が実行されます。上記のコードは「(c+d)」をプライマリ式として食べ、記憶し、解析し、現在のペアを[+, (c+d)]と等しくします。次に、プライマリの右側の二項演算子として「*」を使用して、上記の'if'条件を評価します。この場合、「*」の優先順位は「+」の優先順位よりも高いため、if条件に入ります。

ここで残された重要な質問は「if条件はどのように右側を完全に解析できるのか？」です。特に、この例でASTを正しく構築するには、「(c+d)*e*f」のすべてをRHS式変数として取得する必要があります。これを行うコードは驚くほどシンプルです (コンテキストのために上記の2つのブロックからのコードを複製) : 

.. code-block:: c++

        // BinOpがRHS以降の演算子よりも弱く結合する場合、
        // 保留中の演算子がRHSをそのLHSとして取るようにする
        int NextPrec = GetTokPrecedence();
        if (TokPrec < NextPrec) {
          RHS = ParseBinOpRHS(TokPrec+1, std::move(RHS));
          if (!RHS)
            return nullptr;
        }
        // LHS/RHSをマージ
        LHS = std::make_unique<BinaryExprAST>(BinOp, std::move(LHS),
                                               std::move(RHS));
      }  // whileループの先頭に戻る
    }

この時点で、プライマリのRHS側にある二項演算子が、現在解析中の二項演算子よりも高い優先順位を持つことがわかっています。そのため、演算子がすべて「+」よりも高い優先順位を持つペアのシーケンスは、一緒に解析され「RHS」として返されるべきであることがわかっています。これを行うために、 ``ParseBinOpRHS`` 関数を再帰的に呼び出し、継続するために必要な最小優先順位として「TokPrec+1」を指定します。上記の例では、これにより「(c+d)*e*f」のASTノードがRHSとして返され、それが'+'式のRHSとして設定されます。

最後に、whileループの次の反復で「+g」の部分が解析され、ASTに追加されます。この少しのコード (非自明な14行) で、非常にエレガントな方法で完全に一般的な二項式の解析を正しく処理します。これはこのコードの駆け足ツアーであり、やや微妙です。どのように動作するかを理解するために、いくつかの困難な例で実行することをお勧めします。

これで式の処理が完了しました。この時点で、parserを任意のトークンストリームに指向し、そこから式を構築し、式の一部ではない最初のトークンで停止することができます。次に、関数定義などを処理する必要があります。

残りの解析
==========

次に不足しているのは関数プロトタイプの処理です。Kaleidoscopeでは、これらは'extern'関数宣言と関数本体定義の両方で使用されます。これを行うコードは分かりやすく、あまり興味深くありません (式を乗り切った後では) : 

.. code-block:: c++

    /// prototype
    ///   ::= id '(' id* ')'
    static std::unique_ptr<PrototypeAST> ParsePrototype() {
      if (CurTok != tok_identifier)
        return LogErrorP("Expected function name in prototype");

      std::string FnName = IdentifierStr;
      getNextToken();

      if (CurTok != '(')
        return LogErrorP("Expected '(' in prototype");

      // 引数名のリストを読み取り
      std::vector<std::string> ArgNames;
      while (getNextToken() == tok_identifier)
        ArgNames.push_back(IdentifierStr);
      if (CurTok != ')')
        return LogErrorP("Expected ')' in prototype");

      // 成功
      getNextToken();  // eat ')'

      return std::make_unique<PrototypeAST>(FnName, std::move(ArgNames));
    }

これがあることで、関数定義は非常にシンプルで、プロトタイプに本体を実装するための式を加えただけです: 

.. code-block:: c++

    /// definition ::= 'def' prototype expression
    static std::unique_ptr<FunctionAST> ParseDefinition() {
      getNextToken();  // eat def
      auto Proto = ParsePrototype();
      if (!Proto) return nullptr;

      if (auto E = ParseExpression())
        return std::make_unique<FunctionAST>(std::move(Proto), std::move(E));
      return nullptr;
    }

さらに、'sin'や'cos'のような関数を宣言し、ユーザー関数の前方宣言をサポートするために'extern'をサポートします。これらの'extern'は本体のないプロトタイプだけです: 

.. code-block:: c++

    /// external ::= 'extern' prototype
    static std::unique_ptr<PrototypeAST> ParseExtern() {
      getNextToken();  // eat extern
      return ParsePrototype();
    }

最後に、ユーザーが任意のトップレベル式を入力し、その場で評価できるようにします。これは、それらのために無名のnullary (引数ゼロ) 関数を定義することで処理します: 

.. code-block:: c++

    /// toplevelexpr ::= expression
    static std::unique_ptr<FunctionAST> ParseTopLevelExpr() {
      if (auto E = ParseExpression()) {
        // 無名プロトタイプを作成
        auto Proto = std::make_unique<PrototypeAST>("", std::vector<std::string>());
        return std::make_unique<FunctionAST>(std::move(Proto), std::move(E));
      }
      return nullptr;
    }

すべての部品が揃ったところで、小さなドライバーを構築して実際にこの構築したコードを*実行*できるようにしましょう！

ドライバー
=======

このドライバーは、トップレベルのディスパッチループですべての解析ピースを単純に呼び出します。ここにはあまり興味深いものはないので、トップレベルループだけを含めます。「トップレベル解析」セクションの完全なコードについては `下記 <#full-code-listing>`_ を参照してください。

.. code-block:: c++

    /// top ::= definition | external | expression | ';'
    static void MainLoop() {
      while (true) {
        fprintf(stderr, "ready> ");
        switch (CurTok) {
        case tok_eof:
          return;
        case ';': // トップレベルのセミコロンを無視
          getNextToken();
          break;
        case tok_def:
          HandleDefinition();
          break;
        case tok_extern:
          HandleExtern();
          break;
        default:
          HandleTopLevelExpression();
          break;
        }
      }
    }

ここで最も興味深い部分は、トップレベルのセミコロンを無視することです。なぜでしょうか？基本的な理由は、コマンドラインで「4 + 5」と入力したとき、parserはそれが入力する内容の終わりなのかどうかわからないからです。たとえば、次の行で「def foo...」と入力した場合、4+5はトップレベル式の終わりになります。あるいは「* 6」と入力して式を継続することもできます。トップレベルのセミコロンを持つことで、「4+5;」と入力でき、parserは完了したことを知ることができます。

結論
====

400行未満のコメント付きコード (非コメント、非空白コード240行) で、lexer、parser、ASTビルダーを含むミニマル言語を完全に定義しました。これが完了したことで、実行ファイルはKaleidoscopeコードを検証し、文法的に無効な場合は教えてくれます。たとえば、こちらはサンプルのインタラクションです: 

.. code-block:: bash

    $ ./a.out
    ready> def foo(x y) x+foo(y, 4.0);
    関数定義を解析しました。
    ready> def foo(x y) x+y y;
    関数定義を解析しました。
    トップレベル式を解析しました
    ready> def foo(x y) x+y );
    関数定義を解析しました。
    エラー: 式を期待しているときの未知のトークン
    ready> extern sin(a);
    ready> externを解析しました
    ready> ^D
    $

ここには拡張の余地がたくさんあります。新しいASTノードを定義したり、言語を様々な方法で拡張したりできます。 `次の回 <LangImpl03.html>`_ では、ASTからLLVM中間表現 (IR) を生成する方法について説明します。

全コードリスト
==============

こちらは実行中の例の完全なコードリストです。

.. code-block:: bash

    # コンパイル
    clang++ -g -O3 toy.cpp
    # 実行
    ./a.out

コードはこちらです: 

.. literalinclude:: ../../../examples/Kaleidoscope/Chapter2/toy.cpp
   :language: c++

`次: LLVM IRへのコード生成の実装 <LangImpl03.html>`_

