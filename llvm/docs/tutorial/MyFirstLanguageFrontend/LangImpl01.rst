===================================
Kaleidoscope: Kaleidoscope入門とlexer
===================================

.. contents::
   :local:

Kaleidoscope言語
================

このチュートリアルでは、「 `Kaleidoscope <http://en.wikipedia.org/wiki/Kaleidoscope>`_」 (「美しい」「形」「視点」を意味する語句に由来) という名前のトイ言語を使って説明します。Kaleidoscopeは、関数定義、条件分岐、数学計算などが行える手続き型言語です。このチュートリアル全体を通じて、if/then/else構文、forループ、ユーザー定義演算子、簡単なコマンドラインインターフェースを持つJITコンパイル、デバッグ情報などをサポートするようにKaleidoscopeを拡張していきます。

シンプルに保つため、Kaleidoscopeで唯一のデータ型は64ビット浮動小数点型 (C言語では「double」) です。そのため、すべての値は暗黙的に倍精度であり、言語は型宣言を必要としません。これにより、言語は非常に美しくシンプルな構文を持ちます。たとえば、次の単純な例では `フィボナッチ数 <http://en.wikipedia.org/wiki/Fibonacci_number>`_ を計算します: 

::

    # x番目のフィボナッチ数を計算
    def fib(x)
      if x < 3 then
        1
      else
        fib(x-1)+fib(x-2)

    # この式は40番目の数を計算します
    fib(40)

Kaleidoscopeでは標準ライブラリ関数の呼び出しも可能です。LLVM JITによりこれが非常に簡単になっています。つまり、使用前に「extern」キーワードを使って関数を定義できます (これは相互再帰関数にも便利です) 。例: 

::

    extern sin(arg);
    extern cos(arg);
    extern atan2(arg1 arg2);

    atan2(sin(.4), cos(42))

さらに興味深い例として、第6章では、さまざまな倍率で `マンデルブロ集合を表示 <LangImpl06.html#kicking-the-tires>`_ する小さなKaleidoscopeアプリケーションを作成します。

さあ、この言語の実装に取り組みましょう！

Lexer
=====

言語を実装する際に最初に必要なのは、テキストファイルを処理してその内容を認識する能力です。これを行う従来の方法は、「 `lexer <http://en.wikipedia.org/wiki/Lexical_analysis>`_」 (「scanner」とも呼ばれる) を使って入力を「トークン」に分解することです。lexerが返すトークンには、トークンコードと、場合によってはメタデータ (数値の場合はその数値など) が含まれます。まず、可能性を定義しましょう:

.. code-block:: c++

    // lexerは未知の文字の場合はトークン[0-255]を、既知のものの場合は以下のいずれかを返す
    enum Token {
      tok_eof = -1,

      // commands
      tok_def = -2,
      tok_extern = -3,

      // primary
      tok_identifier = -4,
      tok_number = -5,
    };

    static std::string IdentifierStr; // tok_identifierの場合に設定される
    static double NumVal;             // tok_numberの場合に設定される

lexerが返すトークンは、Token列挙値のいずれかであるか、または「+」のような「未知の」文字であり、その場合はASCII値として返されます。現在のトークンが識別子の場合、``IdentifierStr`` グローバル変数が識別子名を保持します。現在のトークンが数値リテラル (1.0など) の場合、``NumVal`` がその値を保持します。簡単にするためグローバル変数を使用していますが、実際の言語実装では最良の選択ではありません :)

lexerの実際の実装は ``gettok`` という単一の関数です。``gettok`` 関数は標準入力から次のトークンを返すために呼び出されます。その定義は次のように始まります: 

.. code-block:: c++

    /// gettok - 標準入力から次のトークンを返す
    static int gettok() {
      static int LastChar = ' ';

      // 空白文字をスキップ
      while (isspace(LastChar))
        LastChar = getchar();

``gettok`` は、Cの ``getchar()`` 関数を呼び出して標準入力から一文字ずつ文字を読み取ります。認識した文字を消費し、読み取られたが処理されていない最後の文字をLastCharに保存します。最初に行うべきことは、トークン間の空白文字を無視することです。これは上記のループで実現されます。

``gettok`` が次に行う必要があるのは、識別子と「def」のような特定のキーワードを認識することです。Kaleidoscopeはこれを次の単純なループで行います: 

.. code-block:: c++

      if (isalpha(LastChar)) { // identifier: [a-zA-Z][a-zA-Z0-9]*
        IdentifierStr = LastChar;
        while (isalnum((LastChar = getchar())))
          IdentifierStr += LastChar;

        if (IdentifierStr == "def")
          return tok_def;
        if (IdentifierStr == "extern")
          return tok_extern;
        return tok_identifier;
      }

このコードは、識別子を字句解析するたびに「``IdentifierStr``」グローバル変数を設定することに注意してください。また、言語キーワードは同じループによってマッチするため、ここでインラインで処理しています。数値も同様です: 

.. code-block:: c++

      if (isdigit(LastChar) || LastChar == '.') {   // Number: [0-9.]+
        std::string NumStr;
        do {
          NumStr += LastChar;
          LastChar = getchar();
        } while (isdigit(LastChar) || LastChar == '.');

        NumVal = strtod(NumStr.c_str(), 0);
        return tok_number;
      }

これは入力処理のための非常に分かりやすいコードです。入力から数値を読み取る際、Cの ``strtod`` 関数を使用してそれを ``NumVal`` に格納する数値に変換します。これは十分なエラーチェックを行っていないことに注意してください: 「1.23.45.67」を誤って読み取り、「1.23」を入力したかのように処理してしまいます。ぜひ拡張してみてください！ 次にコメントを処理します: 

.. code-block:: c++

      if (LastChar == '#') {
        // 行末までコメント
        do
          LastChar = getchar();
        while (LastChar != EOF && LastChar != '\n' && LastChar != '\r');

        if (LastChar != EOF)
          return gettok();
      }

コメントは行末までスキップしてから次のトークンを返すことで処理します。最後に、入力が上記のどのケースにも一致しない場合、それは「+」のような演算子文字またはファイルの終端です。これらは次のコードで処理されます: 

.. code-block:: c++

      // ファイル終端のチェック。EOFを消費しない
      if (LastChar == EOF)
        return tok_eof;

      // そうでなければ、文字をそのASCII値として返す
      int ThisChar = LastChar;
      LastChar = getchar();
      return ThisChar;
    }

これで、基本的なKaleidoscope言語の完全なlexerができました (lexerの `完全なコード <LangImpl02.html#full-code-listing>`_ はこのチュートリアルの `次章 <LangImpl02.html>`_ で入手できます) 。
次に、これを使って抽象構文木を構築する `シンプルなparserを構築 <LangImpl02.html>`_ します。
それができたら、lexerとparserを一緒に使用できるドライバを含めます。

`次: ParserとASTの実装 <LangImpl02.html>`_

