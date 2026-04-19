# C + Lua vs D + Dua サンプル比較（ホスト/スクリプト分割）

このドキュメントは、**各ケースをホスト側ファイルとスクリプト側ファイルに分割**して並べた比較です。

---

## 1) 戦闘ログ集計

### C + Lua

#### ホスト側（`main.c`）

```c
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdio.h>

static int l_sum(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_Integer total = 0;

    lua_pushnil(L);
    while (lua_next(L, 1) != 0) {
        if (lua_isinteger(L, -1)) {
            total += lua_tointeger(L, -1);
        }
        lua_pop(L, 1);
    }

    lua_pushinteger(L, total);
    return 1;
}

int main(void) {
    lua_State* L = luaL_newstate();
    luaL_openlibs(L);

    lua_pushcfunction(L, l_sum);
    lua_setglobal(L, "sum");

    lua_newtable(L);
    lua_pushstring(L, "name");
    lua_pushstring(L, "Mage");
    lua_settable(L, -3);
    lua_setglobal(L, "stats");

    if (luaL_loadfile(L, "battle.lua") || lua_pcall(L, 0, 1, 0)) {
        fprintf(stderr, "Lua error: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }

    lua_getfield(L, -1, "label");
    printf("label = %s\n", lua_tostring(L, -1));

    lua_close(L);
    return 0;
}
```

#### スクリプト側（`battle.lua`）

```D
local damages = {4, 6, 8, 10}
local total = sum(damages)
local rank = (total > 20) and "A" or "B"

return {
  name = stats.name,
  total = total,
  rank = rank,
  label = stats.name .. "-" .. rank
}
```

### D + Dua

#### ホスト側（`app.d`）

```d
import dua;
import std.stdio;

struct Stats {
    string name;
    int hp;
    int mp;
}

void main() {
    auto engine = new Dua.ScriptEngine();

    auto stats = Stats("Mage", 42, 90);
    int[] damages = [4, 6, 8, 10];

    engine.bind("stats", Dua.Value.reflect(stats));
    engine.bind("damages", Dua.Value.from(damages));

    engine.bindNative("sum", (scope const(Dua.Value)[] args) {
        long total;
        foreach (v; args[0].arrayValue) {
            total += v.toInt();
        }
        return Dua.Value.from(total);
    });

    auto out = engine.runFile("battle.dua");
    writeln(out.toScriptLiteral());
}
```

#### スクリプト側（`battle.dua`）

```D
let total = sum(damages);
let rank = total > 20 ? "A" : "B";

return {
    name = stats.name,
    total = total,
    rank = rank,
    label = stats.name ~ "-" ~ rank
};
```

---

## 2) モジュール分割

### C + Lua

#### ホスト側（`main.c`）

```c
if (luaL_loadstring(L,
    "local rules = require('rules')\n"
    "local p = { attack = 10 }\n"
    "p = rules.buff(p)\n"
    "return p.attack\n") || lua_pcall(L, 0, 1, 0)) {
    // ...
}
```

#### スクリプト側（`rules.lua`）

```D
local rules = {}

function rules.buff(player)
  player.attack = player.attack + 5
  return player
end

function rules.nerf(player)
  player.attack = math.max(player.attack - 2, 0)
  return player
end

return rules
```

### D + Dua

#### ホスト側（`app.d`）

```d
import dua;

void main() {
    auto engine = new Dua.ScriptEngine();
    auto out = engine.runFile("main.dua");
    assert(out.toInt() == 15);
}
```

#### スクリプト側（`main.dua`）

```D
let rules = require("rules");
let p = { attack = 10 };
p = rules.buff(p);
return p.attack;
```

#### スクリプト側（`rules.dua`）

```D
let rules = {
    buff = fn(player) {
        player.attack = player.attack + 5;
        return player;
    },
    nerf = fn(player) {
        player.attack = math.max(player.attack - 2, 0);
        return player;
    }
};

return rules;
```

---

## 3) 価格計算

### C + Lua

#### ホスト側（`main.c`）

```c
if (luaL_loadfile(L, "price.lua") || lua_pcall(L, 0, 1, 0)) {
    // ...
}
```

#### スクリプト側（`price.lua`）

```D
local function sum(head, ...)
  local total = head
  local tail = {...}
  for i = 1, #tail do
    total = total + tail[i]
  end
  return total
end

local function applyCoupon(total, rate)
  local discounted = total * (1.0 - rate)
  local fee = (discounted > 100) and 0 or 5
  return discounted + fee, fee
end

local subtotal = sum(30, 40, 50)
local grand, fee = applyCoupon(subtotal, 0.1)

return { subtotal = subtotal, fee = fee, grand = grand }
```

### D + Dua

#### ホスト側（`app.d`）

```d
import dua;

void main() {
    auto engine = new Dua.ScriptEngine();
    auto out = engine.runFile("price.dua");
    assert(out.kind == Dua.ValueKind.table);
}
```

#### スクリプト側（`price.dua`）

```D
fn sum(head, tail...) {
    let total = head;
    foreach (v; tail) {
        total = total + v;
    }
    return total;
}

fn applyCoupon(total, rate) {
    let discounted = total * (1.0 - rate);
    let fee = discounted > 100 ? 0 : 5;
    return discounted + fee, fee;
}

let subtotal = sum(30, 40, 50);
let grand, fee = applyCoupon(subtotal, 0.1);

return { subtotal = subtotal, fee = fee, grand = grand };
```
