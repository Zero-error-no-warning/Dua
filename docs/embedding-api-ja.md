# Dua 埋め込み API リファレンス（日本語）

この文書は、`module dua` の公開 API と、`source/dua/runtime.d` の `unittest` で実際に保証している挙動を対応付けて説明します。

## 1. 基本オブジェクト

`module dua` では、以下の名前で主要 API を公開しています。

- `Dua.ScriptEngine`
- `Dua.Value`
- `Dua.ValueKind`
- `Dua.RunOutcome`

## 2. ScriptEngine

### 2.1 値と関数の公開

```d
final class Player
{
    int hp;
}

auto engine = new Dua.ScriptEngine();
engine.bind("answer", Dua.Value.from(42));
engine.bindAuto("lives", 3); // Value.from(...) を自動適用

auto player = new Player();
engine.bindAuto("player", player); // class/struct は Value.reflect(...) を自動適用
engine["score"] = 0; // opIndexAssign 経由でも bindAuto 可能

engine.bindNative("mul", (scope const(Dua.Value)[] args) {
    return Dua.Value.from(args[0].toInt() * args[1].toInt());
});

auto result = engine.run("player.hp = player.hp + lives; return mul(answer, 2) + score;");
assert(result.toInt() == 84);
```

### 2.2 実行 API

- `run(source)` / `runSafe(source)`
- `load(source)` / `loadSafe(source)`
- `runFile(path)` / `runFileSafe(path)`
- `loadFile(path)` / `loadFileSafe(path)`

`*Safe` 系は `RunOutcome` を返し、エラー時に例外を直接投げず状態を受け取れます。

```d
auto out = engine.runSafe("return unknownName + 1;");
if (!out.ok) {
    writeln("script error: ", out.errorMessage);
    writeln(out.stackTrace);
}
```

### 2.3 モジュール

```d
engine.registerModule("game.rules", q{
    fn bonus(x) { return x + 10; }
    return { bonus = bonus };
});

auto v = engine.run(q{
    let rules = require("game.rules");
    return rules.bonus(5);
});
assert(v.toInt() == 15);
```

- `registerModule(name, source)` で D 側登録
- スクリプト側は `require(name)` で利用
- `export`/`import ... as ...` のモジュール記法にも対応

`export` / `import` 形式の最小例:

```d
engine.registerModule("math.plus10", q{
    export fn add10(x) { return x + 10; }
});

auto v2 = engine.run(q{
    import "math.plus10" as m;
    return m.add10(7);
});
assert(v2.toInt() == 17);
```

### 2.4 GC（ガベージコレクション）とメモリ管理

- Dua ランタイムは D の GC 管理下で動作し、`ScriptEngine`、クロージャ、コルーチン状態、`Value` の配列/テーブルは GC 到達可能性で管理されます。
- `runtime.d` の標準ライブラリ公開 API に Lua 互換の `collectgarbage()` のような手動 GC 制御関数は存在しません。
- そのため運用上は「エンジンインスタンスのライフサイクルをホスト側で短く保つ」「巨大テーブルを不要になった時点で参照解除する」を基本戦略にしてください。

```d
// 推奨パターン: エンジンの寿命を業務単位で区切る
Dua.Value evalOnce(string source) {
    auto engine = new Dua.ScriptEngine();
    return engine.run(source);
}

// 推奨パターン: 不要な巨大値への参照を落とす
auto e = new Dua.ScriptEngine();
auto large = e.run("return { data = #[1,2,3,4,5] };");
// ... 利用後
large = Dua.Value.init; // 参照を切って GC 対象化しやすくする
```

## 3. D 言語とのクラス・構造体連携

D 側との連携は `Value.reflect` と `bindType` が中心です。

### 3.1 `Value.reflect` の意味

- **struct を `reflect`** した場合: フィールド値とメソッドをテーブル化して公開（値として扱われるため、スクリプトからのフィールド再代入は元 struct を直接更新しない）。
- **class を `reflect`** した場合: フィールド getter/setter が内部的に公開され、スクリプトからの代入が元インスタンスへ反映される。
- class には `__typechain` が付与され、`typeinfo` から継承チェーンを取得可能。

```d
struct Vec2 {
    int x;
    int y;
    int sum() const { return x + y; }
}

class Counter {
    int value;
}

auto eng = new Dua.ScriptEngine();

Vec2 v = Vec2(1, 2);
eng.bind("vec", Dua.Value.reflect(v));
eng.run("vec.x = 100;");
assert(v.x == 1); // struct は元値へ反映されない

auto c = new Counter();
c.value = 3;
eng.bind("counter", Dua.Value.reflect(c));
eng.run("counter.value = 9;");
assert(c.value == 9); // class は setter/getter 経由で反映
```

### 3.2 `bindType` の意味

- `bindType!T("Name")` で `Name.new({...})` / `Name({...})` コンストラクタをスクリプトに公開。
- struct/class とも初期化テーブル 1 引数を受け取り可能。
- `typeinfo(Name)` または `typeinfo(instance)` で型チェーンを取得可能。

```d
struct Player {
    string name;
    int hp;
}

class Enemy {
    string kind;
    int hp;
}
```


## 4. Value

`Dua.Value` は D とスクリプト間の境界型です。

### 4.1 主な変換

- `Dua.Value.from(primitive)`
- `Dua.Value.from(array)`
- `Dua.Value.from(associativeArray)`
- `Dua.Value.reflect(structOrClass)`

```d
auto i = Dua.Value.from(42);
auto arr = Dua.Value.from([1, 2, 3]);
auto aa = Dua.Value.from(["hp": 80, "mp": 30]);
```

### 4.2 主な取り出し

- `toInt()`
- `toFloat()`
- `toBool()`
- `toStringValue()`
- `toScriptLiteral()`
- `to!T()`（テーブル→D struct 変換を含む）

```d
auto n = engine.run("return 1 + 2;").toInt();
auto s = engine.run("return 'abc';").toStringValue();

struct Status { int hp; int mp; }
auto st = engine.run("return { hp = 120, mp = 40 };").to!Status();
assert(st.hp == 120 && st.mp == 40);
```

## 5. エラー処理パターン

```d
auto out = engine.runSafe("return missingVar;");
if (!out.ok) {
    // out.errorMessage
    // out.stackTrace
}
```

アプリケーションでは、`ok` を起点にログ・ユーザー通知・フォールバックへ分岐させるのが基本です。

## 6. `runtime.d` の unittest 網羅一覧（サンプル付き）

以下は `source/dua/runtime.d` で `unittest` されている内容の網羅リストです（2026-04-10 時点）。

1. `for` + `continue` の制御フロー。
2. `foreach` + `break` と `switch/case/default`。
3. 配列 `foreach(index, value)` とテーブル列挙。
4. メタテーブル `__index` / `__newindex` / `__call` / `__len`。
5. 論理演算の短絡評価（`&&`, `||`）。
6. 多値 return と多値代入。
7. 可変長引数 `tail...`。
8. `opBinary~` とメソッドチェーン。
9. `runSafe` の失敗結果（`errorMessage`, `stackTrace`）。
10. `registerModule` + `require` キャッシュ + 標準ライブラリ併用。
11. `export`/`import` モジュール。
12. `Value.reflect` による struct/class のメソッド呼び出し・class フィールド更新。
13. `bindType` した struct の `new` 初期化と `typeinfo`。
14. `bindType` した class のコンストラクタ呼び出しと `typeinfo`。
15. `reflect(struct)` の書き換えが元値へ波及しないこと。
16. `reflect(class)` の setter/getter 経由更新（元インスタンス反映）。
17. スクリプト table 内のプロパティ風 getter/setter（`obj.get` / `obj.set`）。
18. `this` 解決付きメソッド呼び出し。
19. `load` + `call` の D 側直接関数呼び出し。
20. `runFile` / `loadFile` のファイル実行。
21. `runFileSafe` / `loadFileSafe` の失敗系。
22. クロージャ（`makeCounter`）の状態保持。
23. `Value.to!Struct` でのテーブル→struct 変換。
24. `pcall` / `xpcall` の成功・失敗・エラーハンドラ。
25. `setmetatable` / `getmetatable`。
26. `typeof` の kind/length 判定。
27. `setmetatableWithType` + `typeinfo` の型チェーン。
28. ビット演算（`&`, `>>`, `<<`, `^`, `|`）。
29. 計算キー付きテーブルリテラル（`[key] = value`）。
30. 配列要素を持つテーブルの `foreach` 列挙。
31. `#[...]` / `#{...}` リテラル糖衣構文。
32. `coroutine.create/resume/status` と `yield`。
33. `string.trim` / `string.contains` / `string.replace`。
34. `math.min` / `math.max` と `string.len`。
35. 短縮ラムダ `fn x => ...` / `fn(a,b) => ...`。
36. 戻り値なしラムダ構文 `:>` 
37. `map` / `filter`（配列）と `table.map` / `table.filter`（テーブル）。
38. 行コメント・ネストブロックコメントとスライス式。
39. `rawset`

### 6.1 代表サンプル（unittest 対応）

**高階関数（`map` / `filter`、UFCS 併用）**

```d
auto n = engine.run(q{
    let evens = [1, 2, 3, 4, 5]
        .map(fn(x) => x * 2)
        .filter(fn(x) => x % 4 == 0);
    return evens[0] + evens[1]; // 4 + 8
});
assert(n.toInt() == 12);
```

`map(xs, fn)` / `filter(xs, fn)` の入れ子でも同じ結果になります。

**戻り値なしラムダ `:>`（副作用用途）**

```d
auto sinkResult = engine.run(q{
    let box = { v = 0 };
    let sink = fn(x) :> rawset(box, "v", x * 3);
    let out = sink(7);
    return #[box.v, out == null];
});
```

**コルーチン**

```d
auto co = engine.run(q{
    let c = coroutine.create(fn() {
        coroutine.yield(10);
        return 20;
    });
    let a = coroutine.resume(c); // 10
    let b = coroutine.resume(c); // 20
    return #[a, b, coroutine.status(c)];
});
```

**pcall / xpcall**

```d
auto ok = engine.run(q{
    let a = pcall(fn() { return 123; });
    let b = pcall(fn() { error("boom"); });
    return #[a[0], b[0]];
});
```

**module + require キャッシュ**

```d
engine.registerModule("counter.mod", q{
    let n = 0;
    export fn next() { n = n + 1; return n; }
});

auto r = engine.run(q{
    import "counter.mod" as c1;
    import "counter.mod" as c2;
    return #[c1.next(), c2.next()]; // #[1, 2]
});
```

> 補足: 上記は「公開 API が実際にどう使えるか」を示す実例です。破壊的変更時はこの一覧を更新し、対応する `unittest` の追加/修正も同時に行ってください。
