# Dua

Dua は、**D 言語アプリケーションへ組み込み可能な軽量スクリプトランタイム**です。  
このリポジトリでは、字句解析・構文解析・AST・実行エンジンまでを `source/dua` 以下に実装しています。

## 特徴

- D から簡単に埋め込める `Dua.ScriptEngine` API
- 値の橋渡しを行う `Dua.Value`（数値、文字列、配列、テーブル、関数など）
- `run/runSafe`, `load/loadSafe`, `runFile/runFileSafe`, `loadFile/loadFileSafe` による実行導線
- `bind` / `bindNative` による D 側データと関数の公開
- `bindAuto` / `engine["name"] = value` による自動変換バインド（aggregate は reflect）
- `registerModule` + `require(...)` によるモジュール読み込み
- `RunOutcome` によるエラー情報とスタックトレース取得

## クイックスタート

### 1. ビルド

```bash
dub build --compiler=ldc2
```

### 2. 実行

```bash
dub run --compiler=ldc2
```

### 3. 最小埋め込み例

```d
import dua;
import std.stdio;

void main()
{
    auto engine = new Dua.ScriptEngine();

    engine.bind("base", Dua.Value.from(10));
    engine.bindNative("add", (scope const(Dua.Value)[] args) {
        return Dua.Value.from(args[0].toInt() + args[1].toInt());
    });

    auto result = engine.run(q{
        let v = add(base, 5);
        return v;
    });

    writeln(result.toInt()); // 15
}
```

## ドキュメント

公開向けドキュメントは `docs/` に整理しています。

- [公開ガイド / 導入](docs/public-guide-ja.md)
- [言語リファレンス](docs/language-reference-ja.md)
- [埋め込み API リファレンス](docs/embedding-api-ja.md)

## リポジトリ構成

- `source/dua/lexer.d` : Lexer
- `source/dua/parser.d` : Parser
- `source/dua/ast.d` : AST 定義
- `source/dua/runtime.d` : Script 実行エンジン
- `source/dua/value.d` : 値モデルと相互変換
- `source/dua/package.d` : 公開ファサード（`module dua`）

## 開発者向け

```bash
dub test --compiler=ldc2
```

CI を導入する場合も、まずこの 2 コマンド（`build` / `test`）を通す運用を推奨します。
