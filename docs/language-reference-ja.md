# Dua 言語リファレンス（日本語）

このページは、スクリプト記述者向けの簡易リファレンスです。

## 1. 変数と関数

```D
let hp = 100;

fn add(a, b) {
    return a + b;
}

let inc = fn(x) {
    return x + 1;
};

let inc2 = fn x => x + 1;
let add = fn(x, y) => x + y;
let sink = fn(x) :> x + 1;  # 評価するが返り値は返さない
```

- 変数宣言: `let`
- 関数宣言: `fn name(args) { ... }`
- 無名関数: `fn(args) { ... }`
- 無名関数（短縮）: `fn x => expr` / `fn(x, y) => expr`
- 無名関数（戻り値なし短縮）: `fn x :> expr` / `fn(x, y) :> expr`

## 2. 制御構文

```D
if (hp > 0) {
    hp = hp - 1;
} else {
    hp = 0;
}

while (hp > 0) {
    hp = hp - 10;
}

for (let i = 0; i < 3; i = i + 1) {
    # loop
}
```

- `if / else`
- `while`
- `for`
- `foreach`
- `switch / case / default`
- `break / continue`

## 3. 値型

- 数値（整数/浮動小数）
- 文字列
- 真偽値
- 配列
- テーブル
- 関数
- `null`

## 4. 配列・テーブル

```D
let arr = [1, 2, 3];
let user = { name = "alice", level = 3 };
let fixedArr = #[1, 2, 3];
let fixedUser = #{ name = "alice", level = 3 };

user.level = user.level + 1;
let name = user.name;
let first = arr[0];
```

- `#[ ... ]` は固定長配列向けのリテラル表記
- `#{ ... }` は固定メンバーテーブル向けのリテラル表記

## 5. 演算子

```D
let a = 1 + 2 * 3;
let ok = (a > 3) && (a < 10);
let s = "du" ~ "a";
```

- 算術: `+ - * / %`
- 比較: `== != < <= > >=`
- 論理: `&& || !`
- 連結: `~`
- ビット: `& | ^ << >>`

## 6. エラーハンドリング

ホストアプリ側では `runSafe` / `loadSafe` を利用すると、
実行失敗時に `RunOutcome` から `errorMessage` と `stackTrace` を取得できます。

## 7. 関数型ヘルパー

`map` / `filter` は配列とテーブルに対して利用できます。

```D
let doubled = map([1, 2, 3, 4], fn x => x * 2);    # [2, 4, 6, 8]
let even = filter([1, 2, 3, 4], fn x => x % 2 == 0); # [2, 4]

let tbl = { a = 1, b = 2, c = 3 };
let kept = table.filter(tbl, fn(v, k) => v >= 2);  # { b = 2, c = 3 }
```

## 8. モジュール（import / export）

```D
# module source
export let base = 10;
export fn add(x) {
    return x + base;
}

# consumer
import combat.rules as rules;
let value = rules.add(5);
```

- `export let` / `export fn` で公開対象を定義
- `export name;` で既存シンボルを公開
- `import module.path as alias;` でモジュールを読み込み
