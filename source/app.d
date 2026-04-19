import dua;
import std.stdio;

struct Stats
{
    string name;
    int hp;
    int mp;
}

final class Player
{
    string job;
    int level;

    this(string job, int level)
    {
        this.job = job;
        this.level = level;
    }
}

void main()
{
    auto engine = new Dua.ScriptEngine();

    int[] baseDamage = [4, 6, 8];
    auto stats = Stats("Mage", 42, 90);
    auto player = new Player("Wizard", 7);

    engine.bind("baseDamage", Dua.Value.from(baseDamage));
    engine.bind("stats", Dua.Value.reflect(stats));
    engine.bind("player", Dua.Value.reflect(player));

    engine.bindNative("sum", (scope const(Dua.Value)[] args) {
        long total;
        foreach (value; args[0].arrayValue)
        {
            total += value.toInt();
        }
        return Dua.Value.from(total);
    });

    engine.registerModule("player_mod", q{
        let extra = { rankBoost = 5 };
        return extra;
    });

    immutable script = q{
        fn suffix(self, text) {
            return { name = self.name ~ text };
        }

        fn buildProfile(label, total) {
            return {
                label = label,
                total = total,
                job = player.job,
                resource = stats.hp + stats.mp,
                name = label,
                opBinary~ = fn(self, rhs) {
                    return buildProfile(self.label ~ rhs.label, self.total + rhs.total);
                }
            };
        }

        let total = sum(baseDamage);
        let mod = require("player_mod");
        let profile = buildProfile(stats.name, total);
        let merged = profile ~ buildProfile("-elite", 2);
        let chained = merged.suffix("-v1").suffix("-final");
        profile.rank = player.level + 10 + mod.rankBoost;
        profile.title = chained.name;
        profile.debug = json.encode(profile);
        return profile;
    };

    auto outcome = engine.runSafe(script);
    if (!outcome.ok)
    {
        writeln("Dua error: ", outcome.errorMessage);
        if (outcome.stackTrace.length > 0)
        {
            writeln("Stack: ", outcome.stackTrace);
        }
        return;
    }

    writeln("Dua result: ", outcome.value.toScriptLiteral());
    writeln("Supports D arrays, D-style '~' concat, table operator overloads, UFCS, method chaining, and runSafe errors.");
}
