module dua;

public import dua.runtime;
public import dua.value;

/// Namespaced facade for embedding APIs.
///
/// Usage:
/// ---
/// auto engine = new Dua.ScriptEngine();
/// engine.bind("answer", Dua.Value.from(42));
/// ---
struct Dua
{
    alias Value = dua.value.Value;
    alias ValueKind = dua.value.ValueKind;
    alias CallableValue = dua.value.CallableValue;
    alias ScriptEngine = dua.runtime.ScriptEngine;
    alias RunOutcome = dua.runtime.RunOutcome;
}
