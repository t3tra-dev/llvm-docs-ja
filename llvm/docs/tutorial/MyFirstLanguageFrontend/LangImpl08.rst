========================================
Kaleidoscope: オブジェクトコードへのコンパイル
========================================

.. contents::
   :local:

第8章 はじめに
==============

「 `LLVMを使った言語実装 <index.html>`_」チュートリアルの第8章へようこそ。この章では、私たちの言語をオブジェクトファイルへとコンパイルする方法について説明します。

ターゲットの選択
===============

LLVMはクロスコンパイルをネイティブサポートしています。現在のマシンのアーキテクチャにコンパイルすることも、他のアーキテクチャ用にコンパイルすることも同様に簡単です。このチュートリアルでは、現在のマシンをターゲットにします。

ターゲットにしたいアーキテクチャを指定するために、「ターゲットトリプル」と呼ばれる文字列を使用します。これは ``<arch><sub>-<vendor>-<sys>-<abi>`` の形式を取ります (`クロスコンパイルドキュメント <https://clang.llvm.org/docs/CrossCompilation.html#target-triple>`_ を参照してください) 。

例として、clangが考える現在のターゲットトリプルを見ることができます: 

::

    $ clang --version | grep Target
    Target: x86_64-unknown-linux-gnu

このコマンドを実行すると、あなたのマシンでは異なる結果が表示される可能性があります。私とは異なるアーキテクチャやオペレーティングシステムを使用している可能性があるためです。

幸いなことに、現在のマシンをターゲットにするためにターゲットトリプルをハードコーディングする必要はありません。LLVMは現在のマシンのターゲットトリプルを返す ``sys::getDefaultTargetTriple`` を提供しています。

.. code-block:: c++

    auto TargetTriple = sys::getDefaultTargetTriple();

LLVMは、すべてのターゲット機能をリンクすることを要求していません。たとえば、JITのみを使用している場合、アセンブリプリンターは必要ありません。同様に、特定のアーキテクチャのみをターゲットにしている場合は、それらのアーキテクチャの機能のみをリンクできます。

この例では、オブジェクトコード生成用のすべてのターゲットを初期化します。

.. code-block:: c++

    InitializeAllTargetInfos();
    InitializeAllTargets();
    InitializeAllTargetMCs();
    InitializeAllAsmParsers();
    InitializeAllAsmPrinters();

これで、ターゲットトリプルを使用して ``Target`` を取得できます: 

.. code-block:: c++

  std::string Error;
  auto Target = TargetRegistry::lookupTarget(TargetTriple, Error);

  // 要求されたターゲットが見つからなかった場合はエラーを印刷して終了。
  // これは通常、TargetRegistryを初期化し忘れたか、
  // 偽のターゲットトリプルを持っている場合に発生する。
  if (!Target) {
    errs() << Error;
    return 1;
  }

ターゲットマシン
===============

``TargetMachine`` も必要です。このクラスは、ターゲットにしているマシンの完全なマシン記述を提供します。特定の機能 (SSEなど) や特定のCPU (IntelのSandylakeなど) をターゲットにしたい場合は、ここで行います。

LLVMが認識している機能とCPUを確認するには、 ``llc`` を使用できます。たとえば、x86を見てみましょう: 

::

    $ llvm-as < /dev/null | llc -march=x86 -mattr=help
    Available CPUs for this target:

      amdfam10      - Select the amdfam10 processor.
      athlon        - Select the athlon processor.
      athlon-4      - Select the athlon-4 processor.
      ...

    Available features for this target:

      16bit-mode            - 16-bit mode (i8086).
      32bit-mode            - 32-bit mode (80386).
      3dnow                 - Enable 3DNow! instructions.
      3dnowa                - Enable 3DNow! Athlon instructions.
      ...

この例では、追加の機能やターゲットオプションなしで汎用CPUを使用します。

.. code-block:: c++

  auto CPU = "generic";
  auto Features = "";

  TargetOptions opt;
  auto TargetMachine = Target->createTargetMachine(TargetTriple, CPU, Features, opt, Reloc::PIC_);


モジュールの設定
===============

モジュールを設定してターゲットとデータレイアウトを指定する準備ができました。これは厳密には必要ありませんが、 `フロントエンドパフォーマンスガイド <../../Frontend/PerformanceTips.html>`_ でこれを推奨しています。最適化はターゲットとデータレイアウトについて知ることで恩恵を受けます。

.. code-block:: c++

  TheModule->setDataLayout(TargetMachine->createDataLayout());
  TheModule->setTargetTriple(TargetTriple);

オブジェクトコードの生成
======================

オブジェクトコードを生成する準備ができました！ファイルを書き込みたい場所を定義しましょう: 

.. code-block:: c++

  auto Filename = "output.o";
  std::error_code EC;
  raw_fd_ostream dest(Filename, EC, sys::fs::OF_None);

  if (EC) {
    errs() << "Could not open file: " << EC.message();
    return 1;
  }

最後に、オブジェクトコードを生成するパスを定義し、そのパスを実行します: 

.. code-block:: c++

  legacy::PassManager pass;
  auto FileType = CodeGenFileType::ObjectFile;

  if (TargetMachine->addPassesToEmitFile(pass, dest, nullptr, FileType)) {
    errs() << "TargetMachine can't emit a file of this type";
    return 1;
  }

  pass.run(*TheModule);
  dest.flush();

すべてを組み合わせる
==================

これは機能するでしょうか？試してみましょう。コードをコンパイルする必要がありますが、 ``llvm-config`` への引数が前の章と異なることに注意してください。

::

    $ clang++ -g -O3 toy.cpp `llvm-config --cxxflags --ldflags --system-libs --libs all` -o toy

実行して、シンプルな ``average`` 関数を定義してみましょう。完了したらCtrl-Dを押してください。

::

    $ ./toy
    ready> def average(x y) (x + y) * 0.5;
    ^D
    Wrote output.o

オブジェクトファイルができました！これをテストするために、シンプルなプログラムを作成し、出力にリンクしてみましょう。ソースコードは次の通りです: 

.. code-block:: c++

    #include <iostream>

    extern "C" {
        double average(double, double);
    }

    int main() {
        std::cout << "average of 3.0 and 4.0: " << average(3.0, 4.0) << std::endl;
    }

プログラムをoutput.oにリンクし、結果が期待通りであることを確認します: 

::

    $ clang++ main.cpp output.o -o main
    $ ./main
    average of 3.0 and 4.0: 3.5

完全なコードリスト
================

.. literalinclude:: ../../../examples/Kaleidoscope/Chapter8/toy.cpp
   :language: c++

`次: デバッグ情報の追加 <LangImpl09.html>`_
