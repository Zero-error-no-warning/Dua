module dua.runtime;

import dua.ast;
import dua.lexer : lex;
import dua.parser : parse;
import dua.value;
import core.thread : Fiber;
import std.algorithm : canFind, map;
import std.array : array;
import std.conv : to;
import std.datetime.systime : Clock;
import std.exception : enforce;
import std.file : exists, readText, remove, write;
import std.format : format;
import std.math : floor;
import std.string : join, replace, startsWith;
import std.traits : BaseClassesTuple, isAggregateType;
import std.uni : toLower, toUpper;
import std.utf : byDchar;

alias NativeFunction = Value delegate(scope const(Value)[] args);

struct RunOutcome
{
    bool ok;
    Value value;
    string errorMessage;
    string[] stackTrace;
}

final class Environment
{
    Environment parent;
    private Value[string] values;

    this(Environment parent = null)
    {
        this.parent = parent;
    }

    void define(string name, Value value)
    {
        values[name] = value;
    }

    bool contains(string name) const
    {
        return (name in values) !is null || (parent !is null && parent.contains(name));
    }

    Value get(string name)
    {
        if (auto value = name in values)
        {
            return *value;
        }
        if (parent !is null)
        {
            return parent.get(name);
        }
        enforce(false, format("Undefined variable '%s'", name));
        assert(0);
    }

    void assign(string name, Value value)
    {
        if (auto slot = name in values)
        {
            *slot = value;
            return;
        }
        if (parent !is null)
        {
            parent.assign(name, value);
            return;
        }
        enforce(false, format("Cannot assign undefined variable '%s'", name));
    }
}

struct ExecutionResult
{
    Value lastValue;
    bool returned;
    bool broke;
    bool continued;
}

final class NativeCallable : CallableValue
{
    private NativeFunction nativeCallback;

    this(string name, NativeFunction callback)
    {
        super(name);
        this.nativeCallback = callback;
    }

    override Value invoke(Value[] args)
    {
        return nativeCallback(args);
    }
}

final class ScriptCallable : CallableValue
{
    private ScriptEngine engine;
    private Environment closure;
    private string[] parameters;
    private bool variadic;
    private Statement[] body;

    this(string name, ScriptEngine engine, Environment closure, string[] parameters, bool variadic, Statement[] body)
    {
        super(name);
        this.engine = engine;
        this.closure = closure;
        this.parameters = parameters.dup;
        this.variadic = variadic;
        this.body = body.dup;
    }

    override Value invoke(Value[] args)
    {
        auto requiredCount = variadic && parameters.length > 0 ? parameters.length - 1 : parameters.length;
        if (variadic)
        {
            enforce(args.length >= requiredCount,
                format("Function '%s' expected at least %s arguments but got %s", debugName, requiredCount, args.length));
        }
        else
        {
            enforce(args.length == parameters.length,
                format("Function '%s' expected %s arguments but got %s", debugName, parameters.length, args.length));
        }

        auto environment = new Environment(closure);
        if (engine.hasThisContext())
        {
            environment.define("this", engine.currentThisContext());
        }
        foreach (index, parameter; parameters)
        {
            if (variadic && index + 1 == parameters.length)
            {
                environment.define(parameter, Value.from(args[index .. $].dup));
                break;
            }
            environment.define(parameter, args[index]);
        }

        auto result = engine.executeStatements(body, environment);
        return result.lastValue;
    }

    override size_t expectedArity() const
    {
        if (variadic)
        {
            return size_t.max;
        }
        return parameters.length;
    }

    override size_t minimumArity() const
    {
        return variadic && parameters.length > 0 ? parameters.length - 1 : parameters.length;
    }
}

final class ScriptEngine
{
    private final class CoroutineState
    {
        Value entryFunction;
        Fiber fiber;
        Value[] pendingArgs;
        Value[] yieldedValues;
        Value[] returnValues;
        bool started;
        bool dead;
        bool failed;
        string errorMessage;
    }

    private Environment globals;
    private string[] callStack;
    private string[] lastErrorStack;
    private string[string] moduleSources;
    private Value[string] moduleCache;
    private Value[string][] moduleExportScopes;
    private string[] moduleSearchPaths;
    private Value[] moduleLoaders;
    private size_t nextCoroutineId = 1;
    private CoroutineState[size_t] coroutines;
    private CoroutineState activeCoroutine;
    private long[] indexLengthStack;
    private Value[] thisContextStack;

    this()
    {
        globals = new Environment();
        moduleSearchPaths = ["?.dua", "?/init.dua"];
        installStandardLibraries();
        installRequireFunction();
    }

    void bind(string name, Value value)
    {
        globals.define(name, value);
    }

    void bindAuto(T)(string name, auto ref T value)
    {
        static if (is(T == Value))
        {
            bind(name, value);
        }
        else static if (isAggregateType!T)
        {
            bind(name, Value.reflect(value));
        }
        else
        {
            bind(name, Value.from(value));
        }
    }

    void opIndexAssign(T)(auto ref T value, string name)
    {
        bindAuto(name, value);
    }

    Value opIndex(string name)
    {
        return globals.get(name);
    }

    void bindType(T)(string name)
        if (isAggregateType!T)
    {
        Value[] typeChain;
        typeChain ~= Value.from(T.stringof);
        static if (is(T == class))
        {
            static foreach (Base; BaseClassesTuple!T)
            {
                typeChain ~= Value.from(Base.stringof);
            }
        }

        auto constructor = Value.fromFunction(new NativeCallable(name ~ ".new", (scope const(Value)[] args) {
            size_t argOffset = 0;
            if (args.length > 0 && args[0].kind == ValueKind.table)
            {
                if (("new" in args[0].tableValue) !is null)
                {
                    argOffset = 1;
                }
            }
            auto userArgs = args[argOffset .. $];
            enforce(userArgs.length <= 1, format("%s.new([initTable]) expects zero or one argument", name));
            static if (is(T == class))
            {
                auto instance = new T();
                auto reflected = Value.reflect(instance);
                if (userArgs.length == 1)
                {
                    enforce(userArgs[0].kind == ValueKind.table, format("%s.new init argument must be table", name));
                    foreach (key, entry; userArgs[0].tableValue)
                    {
                        auto setterKey = internalFieldSetterPrefix ~ key;
                        if (auto setter = setterKey in reflected.tableValue)
                        {
                            enforce((*setter).kind == ValueKind.function_,
                                format("%s.new setter '%s' is not callable", name, key));
                            Value[] setterArgs = [cast(Value) entry];
                            (*setter).functionValue.invoke(setterArgs);
                        }
                    }
                }
                return reflected;
            }
            else static if (is(T == struct))
            {
                T instance = T.init;
                if (userArgs.length == 1)
                {
                    enforce(userArgs[0].kind == ValueKind.table, format("%s.new init argument must be table", name));
                    instance = (cast(Value) userArgs[0]).to!T();
                }
                return Value.reflect(instance);
            }
        }));

        Value[string] typeTable;
        typeTable["name"] = Value.from(name);
        typeTable["new"] = constructor;
        typeTable["__typechain"] = Value.from(typeChain);

        Value[string] meta;
        meta["__index"] = Value.from(typeTable);
        meta["__call"] = constructor;
        typeTable["__meta"] = Value.from(meta);

        bind(name, Value.from(typeTable));
    }

    void bindNative(string name, NativeFunction callback)
    {
        globals.define(name, Value.fromFunction(new NativeCallable(name, callback)));
    }

    void registerModule(string name, string source)
    {
        moduleSources[name] = source;
    }

    void clearModuleCache()
    {
        moduleCache = null;
    }

    Value run(string source)
    {
        auto result = runSafe(source);
        if (result.ok)
        {
            return result.value;
        }

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ")
            : "";
        enforce(false, result.errorMessage ~ trace);
        assert(0);
    }

    Value runFile(string path)
    {
        auto result = runFileSafe(path);
        if (result.ok)
        {
            return result.value;
        }

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ")
            : "";
        enforce(false, result.errorMessage ~ trace);
        assert(0);
    }

    RunOutcome runSafe(string source)
    {
        return runInEnvironmentSafe(source, new Environment(globals));
    }

    RunOutcome runFileSafe(string path)
    {
        try
        {
            return runSafe(readScriptFile(path));
        }
        catch (Exception error)
        {
            RunOutcome outcome;
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            return outcome;
        }
    }

    void load(string source)
    {
        auto result = loadSafe(source);
        if (result.ok)
        {
            return;
        }

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ")
            : "";
        enforce(false, result.errorMessage ~ trace);
    }

    void loadFile(string path)
    {
        auto result = loadFileSafe(path);
        if (result.ok)
        {
            return;
        }

        auto trace = result.stackTrace.length > 0
            ? "\nStack:\n  " ~ result.stackTrace.join("\n  ")
            : "";
        enforce(false, result.errorMessage ~ trace);
    }

    RunOutcome loadSafe(string source)
    {
        return runInEnvironmentSafe(source, globals);
    }

    RunOutcome loadFileSafe(string path)
    {
        try
        {
            return loadSafe(readScriptFile(path));
        }
        catch (Exception error)
        {
            RunOutcome outcome;
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            return outcome;
        }
    }

    Value getGlobal(string name)
    {
        return globals.get(name);
    }

    Value call(string functionName, scope const(Value)[] args = [])
    {
        auto callable = getGlobal(functionName);
        Value[] copiedArgs;
        foreach (arg; args)
        {
            copiedArgs ~= cast(Value) arg;
        }
        return invokeFunctionValue(callable, copiedArgs);
    }

    private RunOutcome runInEnvironmentSafe(string source, Environment environment)
    {
        callStack.length = 0;
        lastErrorStack.length = 0;
        RunOutcome outcome;
        try
        {
            auto program = parse(lex(source));
            auto result = executeStatements(program.statements, environment);
            outcome.ok = true;
            outcome.value = result.lastValue;
            return outcome;
        }
        catch (Exception error)
        {
            outcome.ok = false;
            outcome.errorMessage = error.msg;
            outcome.stackTrace = lastErrorStack.length > 0 ? lastErrorStack.dup : callStack.dup;
            return outcome;
        }
    }

    private string readScriptFile(string path)
    {
        enforce(path.length > 0, "Script path must not be empty");
        enforce(exists(path), format("Script file not found: %s", path));
        return readText(path);
    }

    ExecutionResult executeStatements(Statement[] statements, Environment environment)
    {
        ExecutionResult result;
        foreach (statement; statements)
        {
            result = executeStatement(statement, environment);
            if (result.returned || result.broke || result.continued)
            {
                return result;
            }
        }
        return result;
    }

    private ExecutionResult executeStatement(Statement statement, Environment environment)
    {
        try
        {
            ExecutionResult result;

            final switch (statement.kind)
            {
                case Statement.Kind.let_:
                    auto values = evaluateExpressionList(statement.expressions, environment);
                    foreach (index, name; statement.names)
                    {
                        auto value = index < values.length ? values[index] : Value.nullValue();
                        environment.define(name, value);
                        result.lastValue = value;
                        if (statement.isExported)
                        {
                            exportSymbol(name, value);
                        }
                    }
                    break;
                case Statement.Kind.assign:
                    auto values = evaluateExpressionList(statement.expressions, environment);
                    foreach (index, target; statement.targets)
                    {
                        auto value = index < values.length ? values[index] : Value.nullValue();
                        assignTarget(target, value, environment);
                        result.lastValue = value;
                    }
                    break;
                case Statement.Kind.expression:
                    result.lastValue = evaluate(statement.expression, environment);
                    break;
                case Statement.Kind.return_:
                    if (statement.expressions.length == 0)
                    {
                        result.lastValue = Value.nullValue();
                    }
                    else if (statement.expressions.length == 1)
                    {
                        result.lastValue = evaluate(statement.expressions[0], environment);
                    }
                    else
                    {
                        Value[] values;
                        foreach (expression; statement.expressions)
                        {
                            values ~= evaluate(expression, environment);
                        }
                        result.lastValue = Value.from(values);
                    }
                    result.returned = true;
                    break;
                case Statement.Kind.functionDecl:
                    auto callable = Value.fromFunction(new ScriptCallable(statement.name, this, environment,
                        statement.parameters, statement.variadic, statement.body));
                    environment.define(statement.name, callable);
                    result.lastValue = callable;
                    if (statement.isExported)
                    {
                        exportSymbol(statement.name, callable);
                    }
                    break;
                case Statement.Kind.import_:
                    auto imported = requireModule(statement.name);
                    environment.define(statement.aliasName, imported);
                    result.lastValue = imported;
                    break;
                case Statement.Kind.export_:
                    exportSymbol(statement.name, environment.get(statement.name));
                    break;
                case Statement.Kind.block:
                    return executeStatements(statement.body, new Environment(environment));
                case Statement.Kind.if_:
                    if (evaluate(statement.condition, environment).truthy())
                    {
                        result = executeStatement(statement.body[0], environment);
                    }
                    else if (statement.elseBranch !is null)
                    {
                        result = executeStatement(statement.elseBranch, environment);
                    }
                    break;
                case Statement.Kind.while_:
                    while (evaluate(statement.condition, environment).truthy())
                    {
                        result = executeStatement(statement.body[0], environment);
                        if (result.returned)
                        {
                            return result;
                        }
                        if (result.broke)
                        {
                            result.broke = false;
                            break;
                        }
                        if (result.continued)
                        {
                            result.continued = false;
                            continue;
                        }
                    }
                    break;
                case Statement.Kind.for_:
                    auto loopEnvironment = new Environment(environment);
                    if (statement.init !is null)
                    {
                        auto initResult = executeStatement(statement.init, loopEnvironment);
                        if (initResult.returned)
                        {
                            return initResult;
                        }
                    }

                    while (statement.condition is null || evaluate(statement.condition, loopEnvironment).truthy())
                    {
                        result = executeStatement(statement.body[0], loopEnvironment);
                        if (result.returned)
                        {
                            return result;
                        }
                        if (result.broke)
                        {
                            result.broke = false;
                            break;
                        }
                        if (statement.incrementStatement !is null)
                        {
                            auto incrementResult = executeStatement(statement.incrementStatement, loopEnvironment);
                            if (incrementResult.returned)
                            {
                                return incrementResult;
                            }
                            result.lastValue = incrementResult.lastValue;
                        }
                        if (result.continued)
                        {
                            result.continued = false;
                            continue;
                        }
                    }
                    break;
                case Statement.Kind.foreach_:
                    auto iterable = evaluate(statement.iterable, environment);
                    if (iterable.kind == ValueKind.array)
                    {
                        foreach (index, item; iterable.arrayValue)
                        {
                            auto itemEnvironment = new Environment(environment);
                            if (statement.iteratorSecondName.length == 0)
                            {
                                itemEnvironment.define(statement.iteratorName, item);
                            }
                            else
                            {
                                itemEnvironment.define(statement.iteratorName, Value.from(cast(long) index));
                                itemEnvironment.define(statement.iteratorSecondName, item);
                            }
                            result = executeStatement(statement.body[0], itemEnvironment);
                            if (result.returned)
                            {
                                return result;
                            }
                            if (result.broke)
                            {
                                result.broke = false;
                                break;
                            }
                            if (result.continued)
                            {
                                result.continued = false;
                                continue;
                            }
                        }
                    }
                    else if (iterable.kind == ValueKind.table)
                    {
                        foreach (key, value; iterable.tableValue)
                        {
                            auto itemEnvironment = new Environment(environment);
                            if (statement.iteratorSecondName.length == 0)
                            {
                                itemEnvironment.define(statement.iteratorName, value);
                            }
                            else
                            {
                                itemEnvironment.define(statement.iteratorName, tableKeyToScriptValue(key));
                                itemEnvironment.define(statement.iteratorSecondName, value);
                            }
                            result = executeStatement(statement.body[0], itemEnvironment);
                            if (result.returned)
                            {
                                return result;
                            }
                            if (result.broke)
                            {
                                result.broke = false;
                                break;
                            }
                            if (result.continued)
                            {
                                result.continued = false;
                                continue;
                            }
                        }
                    }
                    else
                    {
                        enforce(false, "foreach expects array or table");
                    }
                    break;
                case Statement.Kind.switch_:
                    auto target = evaluate(statement.expression, environment);
                    bool matched;
                    foreach (switchCase; statement.switchCases)
                    {
                        if (!switchCase.isDefault && !matched)
                        {
                            matched = valuesEqual(target, evaluate(switchCase.pattern, environment));
                        }
                        else if (switchCase.isDefault && !matched)
                        {
                            matched = true;
                        }

                        if (!matched)
                        {
                            continue;
                        }

                        result = executeStatements(switchCase.body, new Environment(environment));
                        if (result.returned)
                        {
                            return result;
                        }
                        if (result.broke)
                        {
                            result.broke = false;
                            break;
                        }
                        break;
                    }
                    break;
                case Statement.Kind.break_:
                    result.broke = true;
                    break;
                case Statement.Kind.continue_:
                    result.continued = true;
                    break;
                case Statement.Kind.yield_:
                    enforce(activeCoroutine !is null, "yield can only be used inside a running coroutine");
                    if (statement.expressions.length == 0)
                    {
                        activeCoroutine.yieldedValues = [Value.nullValue()];
                    }
                    else
                    {
                        activeCoroutine.yieldedValues = evaluateExpressionList(statement.expressions, environment);
                    }
                    Fiber.yield();
                    result.lastValue = activeCoroutine.pendingArgs.length > 0
                        ? activeCoroutine.pendingArgs[0]
                        : Value.nullValue();
                    break;
            }

            return result;
        }
        catch (Exception error)
        {
            auto location = statementLocation(statement);
            throw makeContextualException(error.msg, location, "statement");
        }
    }

    private Value[] evaluateExpressionList(Expression[] expressions, Environment environment)
    {
        if (expressions.length == 0)
        {
            return [];
        }

        if (expressions.length == 1)
        {
            auto value = evaluate(expressions[0], environment);
            if (value.kind == ValueKind.array)
            {
                return value.arrayValue.dup;
            }
            return [value];
        }

        Value[] values;
        foreach (expression; expressions)
        {
            values ~= evaluate(expression, environment);
        }
        return values;
    }

    private void assignTarget(Expression target, Value value, Environment environment)
    {
        try
        {
            switch (target.kind)
            {
                case Expression.Kind.variable:
                    environment.assign(target.identifier, value);
                    return;
                case Expression.Kind.get:
                    auto container = evaluate(target.left, environment);
                    enforce(container.kind == ValueKind.table,
                        "Property assignment currently supports tables/reflected structs/classes");
                    if (auto property = target.identifier in container.tableValue)
                    {
                        if (property.kind == ValueKind.function_
                            && property.functionValue.expectedArity() == 1)
                        {
                            invokeFunctionValueWithThis(*property, [value], container);
                            return;
                        }
                    }
                    auto setterKey = internalFieldSetterPrefix ~ target.identifier;
                    if (auto setter = setterKey in container.tableValue)
                    {
                        invokeFunctionValue(*setter, [value]);
                        return;
                    }
                    if (!applyTableNewIndex(container, target.identifier, value))
                    {
                        container.tableValue[target.identifier] = value;
                    }
                    return;
                case Expression.Kind.index:
                    auto container = evaluate(target.left, environment);
                    enforce(target.operatorSymbol != "..", "Slice cannot be an assignment target");
                    auto index = evaluate(target.right, environment);
                    if (container.kind == ValueKind.array)
                    {
                        auto position = cast(size_t) index.toInt();
                        enforce(position < container.arrayValue.length, "Array index out of range");
                        container.arrayValue[position] = value;
                        return;
                    }
                    if (container.kind == ValueKind.table)
                    {
                        auto key = index.toHostString();
                        if (!applyTableNewIndex(container, key, value))
                        {
                            container.tableValue[key] = value;
                        }
                        return;
                    }
                    break;
                default:
                    break;
            }

            enforce(false, "Invalid assignment target");
        }
        catch (Exception error)
        {
            auto location = expressionLocation(target);
            throw makeContextualException(error.msg, location, "assignment");
        }
    }

    private Value evaluate(Expression expression, Environment environment)
    {
        try
        {
            final switch (expression.kind)
            {
                case Expression.Kind.literal:
                    return expression.literalValue;
                case Expression.Kind.variable:
                    return environment.get(expression.identifier);
                case Expression.Kind.unary:
                    switch (expression.operatorSymbol)
                    {
                        case "$":
                            enforce(indexLengthStack.length > 0, "$ is only available inside index expressions");
                            return Value.from(indexLengthStack[$ - 1]);
                        case "-":
                            auto right = evaluate(expression.right, environment);
                            return right.kind == ValueKind.integer
                                ? Value.from(-right.integerValue)
                                : Value.from(-right.toFloat());
                        case "!":
                            auto right = evaluate(expression.right, environment);
                            return Value.from(!right.truthy());
                        default:
                            enforce(false, format("Unsupported unary operator '%s'", expression.operatorSymbol));
                            assert(0);
                    }
                case Expression.Kind.binary:
                    if (expression.operatorSymbol == "&&")
                    {
                        auto left = evaluate(expression.left, environment);
                        if (!left.truthy())
                        {
                            return Value.from(false);
                        }

                        auto right = evaluate(expression.right, environment);
                        return Value.from(right.truthy());
                    }

                    if (expression.operatorSymbol == "||")
                    {
                        auto left = evaluate(expression.left, environment);
                        if (left.truthy())
                        {
                            return Value.from(true);
                        }

                        auto right = evaluate(expression.right, environment);
                        return Value.from(right.truthy());
                    }

                    return evaluateBinary(expression.operatorSymbol,
                        evaluate(expression.left, environment),
                        evaluate(expression.right, environment));
                case Expression.Kind.ternary:
                    return evaluate(expression.left, environment).truthy()
                        ? evaluate(expression.middle, environment)
                        : evaluate(expression.right, environment);
                case Expression.Kind.call:
                    auto args = expression.arguments.map!(arg => evaluate(arg, environment)).array;
                    return evaluateCall(expression.left, args, environment);
                case Expression.Kind.array:
                    return Value.from(expression.arguments.map!(arg => evaluate(arg, environment)).array);
                case Expression.Kind.table:
                    Value[string] entries;
                    foreach (entry; expression.entries)
                    {
                        auto key = entry.key;
                        if (entry.isArrayEntry)
                        {
                            key = entry.key;
                        }
                        else if (entry.keyExpression !is null)
                        {
                            key = evaluate(entry.keyExpression, environment).toHostString();
                        }
                        entries[key] = evaluate(entry.value, environment);
                    }
                    return Value.from(entries);
                case Expression.Kind.function_:
                    return Value.fromFunction(new ScriptCallable("anonymous", this, environment,
                        expression.parameters, expression.variadic, expression.body));
                case Expression.Kind.get:
                    auto container = evaluate(expression.left, environment);
                    enforce(container.kind == ValueKind.table,
                        "Property access currently supports tables/reflected structs/classes");
                    auto getterKey = internalFieldGetterPrefix ~ expression.identifier;
                    if (auto getter = getterKey in container.tableValue)
                    {
                        auto refreshed = invokeFunctionValueWithThis(*getter, [], container);
                        container.tableValue[expression.identifier] = refreshed;
                        return refreshed;
                    }
                    if (auto value = expression.identifier in container.tableValue)
                    {
                        if (value.kind == ValueKind.function_
                            && value.functionValue.expectedArity() == 0)
                        {
                            return invokeFunctionValueWithThis(*value, [], container);
                        }
                        return *value;
                    }
                    Value resolved;
                    if (resolveTableIndex(container, expression.identifier, resolved))
                    {
                        return resolved;
                    }
                    enforce(false, format("Unknown property '%s'", expression.identifier));
                    assert(0);
                case Expression.Kind.index:
                    auto container = evaluate(expression.left, environment);
                    bool pushedLengthContext;
                    if (canMeasureLength(container))
                    {
                        indexLengthStack ~= measuredLength(container);
                        pushedLengthContext = true;
                    }
                    scope (exit)
                    {
                        if (pushedLengthContext)
                        {
                            indexLengthStack.length = indexLengthStack.length - 1;
                        }
                    }
                    if (expression.operatorSymbol == "..")
                    {
                        enforce(container.kind == ValueKind.array, "Slicing currently supports arrays only");
                        auto start = evaluate(expression.middle, environment).toInt();
                        auto finish = evaluate(expression.right, environment).toInt();
                        enforce(start >= 0 && finish >= start, "Invalid slice range");
                        auto lowerBound = cast(size_t) start;
                        auto upperBound = cast(size_t) finish;
                        enforce(upperBound <= container.arrayValue.length, "Slice end out of range");
                        Value[] sliced;
                        if (lowerBound < upperBound)
                        {
                            sliced = container.arrayValue[lowerBound .. upperBound].dup;
                        }
                        return Value.from(sliced);
                    }
                    auto index = evaluate(expression.right, environment);
                    if (container.kind == ValueKind.array)
                    {
                        auto position = cast(size_t) index.toInt();
                        enforce(position < container.arrayValue.length, "Array index out of range");
                        return container.arrayValue[position];
                    }
                    if (container.kind == ValueKind.table)
                    {
                        auto key = index.toHostString();
                        Value resolved;
                        if (resolveTableIndex(container, key, resolved))
                        {
                            return resolved;
                        }
                        return Value.nullValue();
                    }
                    enforce(false, "Indexing currently supports arrays and tables");
                    assert(0);
            }
        }
        catch (Exception error)
        {
            auto location = expressionLocation(expression);
            throw makeContextualException(error.msg, location, "expression");
        }
    }

    private string statementLocation(Statement statement) const
    {
        if (statement.line == 0 || statement.column == 0)
        {
            return "unknown";
        }
        return format("%s:%s", statement.line, statement.column);
    }

    private string expressionLocation(Expression expression) const
    {
        if (expression.line == 0 || expression.column == 0)
        {
            return "unknown";
        }
        return format("%s:%s", expression.line, expression.column);
    }

    private Exception makeContextualException(string message, string location, string context)
    {
        if (startsWith(message, "["))
        {
            return new Exception(message);
        }
        return new Exception(format("[%s @ %s] %s", context, location, message));
    }

    private Value evaluateBinary(string operatorSymbol, Value left, Value right)
    {
        if (auto overloaded = tryCallBinaryOverload(operatorSymbol, left, right))
        {
            return *overloaded;
        }

        switch (operatorSymbol)
        {
            case "~":
                if (left.kind == ValueKind.array && right.kind == ValueKind.array)
                {
                    auto combined = left.arrayValue.dup;
                    combined ~= right.arrayValue;
                    return Value.from(combined);
                }
                return Value.from(stringify(left) ~ stringify(right));
            case "+":
                if (left.kind == ValueKind.integer && right.kind == ValueKind.integer)
                {
                    return Value.from(left.integerValue + right.integerValue);
                }
                return Value.from(left.toFloat() + right.toFloat());
            case "-":
                if (left.kind == ValueKind.integer && right.kind == ValueKind.integer)
                {
                    return Value.from(left.integerValue - right.integerValue);
                }
                return Value.from(left.toFloat() - right.toFloat());
            case "*":
                if (left.kind == ValueKind.integer && right.kind == ValueKind.integer)
                {
                    return Value.from(left.integerValue * right.integerValue);
                }
                return Value.from(left.toFloat() * right.toFloat());
            case "/":
                return Value.from(left.toFloat() / right.toFloat());
            case "%":
                return Value.from(left.toInt() % right.toInt());
            case "&":
                return Value.from(left.toInt() & right.toInt());
            case "|":
                return Value.from(left.toInt() | right.toInt());
            case "^":
                return Value.from(left.toInt() ^ right.toInt());
            case "<<":
                return Value.from(left.toInt() << right.toInt());
            case ">>":
                return Value.from(left.toInt() >> right.toInt());
            case "==":
                if (auto overloadedEq = tryCallEqualityOverload(left, right))
                {
                    return Value.from(overloadedEq.truthy());
                }
                return Value.from(valuesEqual(left, right));
            case "!=":
                if (auto overloadedEq = tryCallEqualityOverload(left, right))
                {
                    return Value.from(!overloadedEq.truthy());
                }
                return Value.from(!valuesEqual(left, right));
            case "<":
                return Value.from(left.toFloat() < right.toFloat());
            case "<=":
                return Value.from(left.toFloat() <= right.toFloat());
            case ">":
                return Value.from(left.toFloat() > right.toFloat());
            case ">=":
                return Value.from(left.toFloat() >= right.toFloat());
            default:
                enforce(false, format("Unsupported binary operator '%s'", operatorSymbol));
                assert(0);
        }
    }

    private Value evaluateCall(Expression calleeExpression, Value[] args, Environment environment)
    {
        if (calleeExpression.kind == Expression.Kind.get)
        {
            auto receiver = evaluate(calleeExpression.left, environment);
            return callMethodOrUfcs(receiver, calleeExpression.identifier, args, environment);
        }

        auto callee = evaluate(calleeExpression, environment);
        if (callee.kind == ValueKind.table)
        {
            Value callValue;
            if (lookupMetamethod(callee, "__call", callValue))
            {
                Value[] bridgedArgs = [callee];
                bridgedArgs ~= args;
                return invokeFunctionValue(callValue, bridgedArgs);
            }
        }
        return invokeFunctionValue(callee, args);
    }

    private Value callMethodOrUfcs(Value receiver, string functionName, Value[] args, Environment environment)
    {
        if (receiver.kind == ValueKind.table)
        {
            if (auto method = functionName in receiver.tableValue)
            {
                enforce(method.kind == ValueKind.function_,
                    format("Property '%s' exists but is not callable", functionName));
                return invokeFunctionValueWithThis(*method, args, receiver);
            }
        }

        if (auto ufcsFunction = resolveUfcs(functionName, environment))
        {
            Value[] ufcsArgs = [receiver];
            ufcsArgs ~= args;
            return invokeFunctionValue(*ufcsFunction, ufcsArgs);
        }

        enforce(false, format("No method or UFCS function named '%s'", functionName));
        assert(0);
    }

    private Value invokeFunctionValueWithThis(Value callable, Value[] args, Value thisValue)
    {
        thisContextStack ~= thisValue;
        scope (exit)
        {
            thisContextStack.length = thisContextStack.length - 1;
        }
        return invokeFunctionValue(callable, args);
    }

    private bool hasThisContext() const
    {
        return thisContextStack.length > 0;
    }

    private Value currentThisContext() const
    {
        assert(thisContextStack.length > 0);
        return cast(Value) thisContextStack[$ - 1];
    }

    private Value* tryCallBinaryOverload(string operatorSymbol, Value left, Value right)
    {
        if (left.kind == ValueKind.table)
        {
            auto slot = "opBinary" ~ operatorSymbol;
            Value functionValue;
            if (lookupMetamethod(left, slot, functionValue))
            {
                return callTableBinaryOverload(functionValue, left, right);
            }
        }
        if (right.kind == ValueKind.table)
        {
            auto slot = "opBinaryRight" ~ operatorSymbol;
            Value functionValue;
            if (lookupMetamethod(right, slot, functionValue))
            {
                return callTableBinaryOverload(functionValue, right, left);
            }
        }
        return null;
    }

    private Value* tryCallEqualityOverload(Value left, Value right)
    {
        if (left.kind == ValueKind.table)
        {
            Value functionValue;
            if (lookupMetamethod(left, "__eq", functionValue))
            {
                return callTableBinaryOverload(functionValue, left, right);
            }
        }
        if (right.kind == ValueKind.table)
        {
            Value functionValue;
            if (lookupMetamethod(right, "__eq", functionValue))
            {
                return callTableBinaryOverload(functionValue, right, left);
            }
        }
        return null;
    }

    private Value* callTableBinaryOverload(Value functionValue, Value selfValue, Value otherValue)
    {
        enforce(functionValue.kind == ValueKind.function_,
            "Table operator overload must be a function value");
        Value[] args = [selfValue, otherValue];
        auto result = new Value();
        *result = invokeFunctionValue(functionValue, args);
        return result;
    }

    private Value invokeFunctionValue(Value callable, Value[] args)
    {
        enforce(callable.kind == ValueKind.function_, "Only functions are callable");
        auto name = callable.functionValue.debugName;
        callStack ~= name;
        scope (exit)
        {
            if (callStack.length > 0)
            {
                callStack.length = callStack.length - 1;
            }
        }
        try
        {
            return callable.functionValue.invoke(args);
        }
        catch (Exception error)
        {
            lastErrorStack = callStack.dup;
            throw error;
        }
    }

    private string stringify(Value value)
    {
        if (value.kind == ValueKind.table)
        {
            Value toStringFunction;
            if (lookupMetamethod(value, "__tostring", toStringFunction))
            {
                auto rendered = invokeFunctionValue(toStringFunction, [value]);
                return rendered.toHostString();
            }
        }
        return value.toHostString();
    }

    private bool canMeasureLength(Value value) const
    {
        return value.kind == ValueKind.array
            || value.kind == ValueKind.table
            || value.kind == ValueKind.string_;
    }

    private long measuredLength(Value value)
    {
        if (value.kind == ValueKind.array)
        {
            return cast(long) value.arrayValue.length;
        }
        if (value.kind == ValueKind.string_)
        {
            return cast(long) value.stringValue.length;
        }
        if (value.kind == ValueKind.table)
        {
            Value lengthMeta;
            if (lookupMetamethod(value, "__length", lengthMeta) || lookupMetamethod(value, "__len", lengthMeta))
            {
                enforce(lengthMeta.kind == ValueKind.function_, "__length/__len must be a function");
                auto measured = invokeFunctionValue(lengthMeta, [value]);
                return measured.toInt();
            }
            return cast(long) value.tableValue.length;
        }
        enforce(false, "length supports arrays, tables, and strings only");
        assert(0);
    }

    private Value measureLengthValue(scope const(Value)[] args)
    {
        enforce(args.length == 1, "length(value) expects one argument");
        return Value.from(measuredLength(cast(Value) args[0]));
    }

    private Value[] extractTypeChain(Value value)
    {
        Value[] chain;
        if (value.kind == ValueKind.table)
        {
            if (auto reflected = "__typechain" in value.tableValue)
            {
                if (reflected.kind == ValueKind.array)
                {
                    foreach (name; reflected.arrayValue)
                    {
                        chain ~= Value.from(name.toHostString());
                    }
                }
            }
        }
        return chain;
    }

    private Value buildTypeInfo(Value value)
    {
        auto chain = extractTypeChain(value);
        Value[string] info;
        info["kind"] = Value.from(value.kind.to!string);
        info["chain"] = Value.from(chain.dup);
        return Value.from(info);
    }

    private Value typeOfValue(scope const(Value)[] args)
    {
        enforce(args.length == 1, "typeof(value) expects one argument");
        return buildTypeInfo(cast(Value) args[0]);
    }

    private Value setMetatableWithType(scope const(Value)[] args)
    {
        enforce(args.length >= 2, "setmetatableWithType(table, meta, ...types) expects at least two arguments");
        enforce(args[0].kind == ValueKind.table, "setmetatableWithType first argument must be table");
        enforce(args[1].kind == ValueKind.table || args[1].kind == ValueKind.null_,
            "setmetatableWithType second argument must be table or null");
        auto table = cast(Value) args[0];
        if (args[1].kind == ValueKind.null_)
        {
            table.tableValue.remove("__meta");
        }
        else
        {
            table.tableValue["__meta"] = cast(Value) args[1];
        }

        if (args.length == 2)
        {
            table.tableValue.remove("__typechain");
            return table;
        }

        Value[] typeChain;
        foreach (typeName; args[2 .. $])
        {
            typeChain ~= Value.from((cast(Value) typeName).toHostString());
        }
        table.tableValue["__typechain"] = Value.from(typeChain);
        return table;
    }

    private Value mapValue(scope const(Value)[] args)
    {
        enforce(args.length == 2, "map(collection, fn) expects two arguments");
        auto collection = cast(Value) args[0];
        auto mapper = cast(Value) args[1];
        enforce(mapper.kind == ValueKind.function_, "map second argument must be function");

        if (collection.kind == ValueKind.array)
        {
            Value[] mapped;
            foreach (index, item; collection.arrayValue)
            {
                mapped ~= invokeCollectionCallback(mapper, item, Value.from(cast(long) index));
            }
            return Value.from(mapped);
        }

        if (collection.kind == ValueKind.table)
        {
            Value[string] mapped;
            foreach (key, item; collection.tableValue)
            {
                mapped[key] = invokeCollectionCallback(mapper, item, tableKeyToScriptValue(key));
            }
            return Value.from(mapped);
        }

        enforce(false, format("map supports arrays and tables only (got %s)", collection.kind));
        assert(0);
    }

    private Value filterValue(scope const(Value)[] args)
    {
        enforce(args.length == 2, "filter(collection, fn) expects two arguments");
        auto collection = cast(Value) args[0];
        auto predicate = cast(Value) args[1];
        enforce(predicate.kind == ValueKind.function_, "filter second argument must be function");

        if (collection.kind == ValueKind.array)
        {
            Value[] filtered;
            foreach (index, item; collection.arrayValue)
            {
                auto keep = invokeCollectionCallback(predicate, item, Value.from(cast(long) index));
                if (keep.truthy())
                {
                    filtered ~= item;
                }
            }
            return Value.from(filtered);
        }

        if (collection.kind == ValueKind.table)
        {
            Value[string] filtered;
            foreach (key, item; collection.tableValue)
            {
                auto keep = invokeCollectionCallback(predicate, item, tableKeyToScriptValue(key));
                if (keep.truthy())
                {
                    filtered[key] = item;
                }
            }
            return Value.from(filtered);
        }

        enforce(false, format("filter supports arrays and tables only (got %s)", collection.kind));
        assert(0);
    }

    private Value invokeCollectionCallback(Value callback, Value value, Value keyOrIndex)
    {
        auto expected = callback.functionValue.expectedArity();
        if (expected == 0)
        {
            return invokeFunctionValue(callback, []);
        }
        if (expected == 1)
        {
            return invokeFunctionValue(callback, [value]);
        }
        if (expected != size_t.max)
        {
            return invokeFunctionValue(callback, [value, keyOrIndex]);
        }

        auto minimum = callback.functionValue.minimumArity();
        if (minimum == 0)
        {
            return invokeFunctionValue(callback, []);
        }
        if (minimum == 1)
        {
            return invokeFunctionValue(callback, [value]);
        }
        return invokeFunctionValue(callback, [value, keyOrIndex]);
    }

    private Value* resolveUfcs(string functionName, Environment environment)
    {
        if (environment.contains(functionName))
        {
            auto functionValue = environment.get(functionName);
            if (functionValue.kind == ValueKind.function_)
            {
                auto resolved = new Value();
                *resolved = functionValue;
                return resolved;
            }
        }
        if (globals.contains(functionName))
        {
            auto functionValue = globals.get(functionName);
            if (functionValue.kind == ValueKind.function_)
            {
                auto resolved = new Value();
                *resolved = functionValue;
                return resolved;
            }
        }
        return null;
    }

    private bool resolveTableIndex(Value container, string key, out Value resolved)
    {
        if (auto direct = key in container.tableValue)
        {
            resolved = *direct;
            return true;
        }

        Value indexMeta;
        if (lookupMetamethod(container, "__index", indexMeta))
        {
            if (indexMeta.kind == ValueKind.function_)
            {
                resolved = invokeFunctionValue(indexMeta, [container, Value.from(key)]);
                return true;
            }
            if (indexMeta.kind == ValueKind.table)
            {
                if (auto fallback = key in indexMeta.tableValue)
                {
                    resolved = *fallback;
                    return true;
                }
            }
        }

        return false;
    }

    private Value tableKeyToScriptValue(string key)
    {
        try
        {
            auto numericKey = key.to!long();
            if (numericKey.to!string == key)
            {
                return Value.from(numericKey);
            }
        }
        catch (Exception)
        {
        }
        return Value.from(key);
    }

    private bool applyTableNewIndex(Value container, string key, Value value)
    {
        if (auto directMeta = "__newindex" in container.tableValue)
        {
            if (directMeta.kind == ValueKind.function_)
            {
                invokeFunctionValue(*directMeta, [container, Value.from(key), value]);
                return true;
            }
            if (directMeta.kind == ValueKind.table)
            {
                directMeta.tableValue[key] = value;
                return true;
            }
        }

        Value newIndexMeta;
        if (lookupMetamethod(container, "__newindex", newIndexMeta))
        {
            if (newIndexMeta.kind == ValueKind.function_)
            {
                invokeFunctionValue(newIndexMeta, [container, Value.from(key), value]);
                return true;
            }
            if (newIndexMeta.kind == ValueKind.table)
            {
                if (auto meta = "__meta" in container.tableValue)
                {
                    if (meta.kind == ValueKind.table)
                    {
                        if (auto nested = "__newindex" in meta.tableValue)
                        {
                            if (nested.kind == ValueKind.table)
                            {
                                nested.tableValue[key] = value;
                                return true;
                            }
                        }
                    }
                }
            }
        }
        return false;
    }

    private bool lookupMetamethod(Value container, string key, out Value method)
    {
        if (auto direct = key in container.tableValue)
        {
            method = *direct;
            return true;
        }

        if (auto meta = "__meta" in container.tableValue)
        {
            if (meta.kind == ValueKind.table)
            {
                if (auto nested = key in meta.tableValue)
                {
                    method = *nested;
                    return true;
                }
            }
        }
        return false;
    }

    private void installRequireFunction()
    {
        bindNative("require", (scope const(Value)[] args) {
            enforce(args.length == 1, "require(name) expects exactly one argument");
            return requireModule(args[0].toHostString());
        });
        bindNative("addModulePath", (scope const(Value)[] args) {
            enforce(args.length == 1, "addModulePath(path) expects one argument");
            moduleSearchPaths ~= args[0].toHostString();
            return Value.nullValue();
        });
        bindNative("setModuleLoaders", (scope const(Value)[] args) {
            moduleLoaders.length = 0;
            foreach (loader; args)
            {
                enforce(loader.kind == ValueKind.function_, "setModuleLoaders expects function arguments");
                moduleLoaders ~= cast(Value) loader;
            }
            return Value.nullValue();
        });
        bindNative("addModuleLoader", (scope const(Value)[] args) {
            enforce(args.length == 1, "addModuleLoader(loader) expects one argument");
            enforce(args[0].kind == ValueKind.function_, "addModuleLoader expects a function");
            moduleLoaders ~= cast(Value) args[0];
            return Value.nullValue();
        });

        Value[string] packageLib;
        packageLib["require"] = globals.get("require");
        packageLib["addPath"] = Value.fromFunction(new NativeCallable("package.addPath", (scope const(Value)[] args) {
            enforce(args.length == 1, "package.addPath(path) expects one argument");
            moduleSearchPaths ~= args[0].toHostString();
            return Value.nullValue();
        }));
        packageLib["addLoader"] = Value.fromFunction(new NativeCallable("package.addLoader", (scope const(Value)[] args) {
            enforce(args.length == 1, "package.addLoader(loader) expects one argument");
            enforce(args[0].kind == ValueKind.function_, "package.addLoader expects a function");
            moduleLoaders ~= cast(Value) args[0];
            return Value.nullValue();
        }));
        packageLib["clearLoaders"] = Value.fromFunction(new NativeCallable("package.clearLoaders", (scope const(Value)[] args) {
            enforce(args.length == 0, "package.clearLoaders() takes no arguments");
            moduleLoaders.length = 0;
            return Value.nullValue();
        }));
        packageLib["loaded"] = Value.fromFunction(new NativeCallable("package.loaded", (scope const(Value)[] args) {
            enforce(args.length == 1, "package.loaded(name) expects one argument");
            auto name = args[0].toHostString();
            if (auto cached = name in moduleCache)
            {
                return *cached;
            }
            return Value.nullValue();
        }));
        packageLib["path"] = Value.from(moduleSearchPaths.map!(item => Value.from(item)).array);
        packageLib["loaders"] = Value.from(moduleLoaders.dup);
        globals.define("package", Value.from(packageLib));
    }

    private void syncPackageConfigFromGlobals()
    {
        if (!globals.contains("package"))
        {
            return;
        }
        auto packageValue = globals.get("package");
        if (packageValue.kind != ValueKind.table)
        {
            return;
        }
        if (auto paths = "path" in packageValue.tableValue)
        {
            if (paths.kind == ValueKind.array)
            {
                moduleSearchPaths.length = 0;
                foreach (item; paths.arrayValue)
                {
                    moduleSearchPaths ~= item.toHostString();
                }
            }
        }
    }

    private Value requireModule(string name)
    {
        syncPackageConfigFromGlobals();
        if (auto cached = name in moduleCache)
        {
            return *cached;
        }

        auto source = name in moduleSources;
        if (source is null)
        {
            auto resolved = resolveModuleSource(name);
            if (resolved.length > 0)
            {
                moduleSources[name] = resolved;
                source = name in moduleSources;
            }
        }
        enforce(source !is null, format("Module '%s' is not registered", name));

        auto program = parse(lex(*source));
        auto moduleEnvironment = new Environment(globals);
        Value[string] exportScope;
        moduleExportScopes ~= exportScope;
        scope(failure)
        {
            if (moduleExportScopes.length > 0)
            {
                moduleExportScopes.length -= 1;
            }
        }
        auto result = executeStatements(program.statements, moduleEnvironment);
        auto exports = moduleExportScopes[$ - 1];
        moduleExportScopes.length -= 1;

        auto moduleValue = exports.length > 0 ? Value.from(exports) : result.lastValue;
        moduleCache[name] = moduleValue;
        return moduleValue;
    }

    private void exportSymbol(string name, Value value)
    {
        enforce(moduleExportScopes.length > 0, "export can only be used inside module source");
        moduleExportScopes[$ - 1][name] = value;
    }

    private string resolveModuleSource(string moduleName)
    {
        foreach (loader; moduleLoaders)
        {
            auto loaded = invokeFunctionValue(loader, [Value.from(moduleName)]);
            if (loaded.kind == ValueKind.string_ && loaded.stringValue.length > 0)
            {
                return loaded.stringValue;
            }
        }

        auto normalized = moduleName.replace(".", "/");
        foreach (pattern; moduleSearchPaths)
        {
            auto path = pattern.replace("?", normalized);
            if (exists(path))
            {
                return readText(path);
            }
        }
        return "";
    }

    private Value createCoroutine(Value functionValue)
    {
        enforce(functionValue.kind == ValueKind.function_, "coroutine.create(fn) expects function");
        auto state = new CoroutineState();
        state.entryFunction = functionValue;

        state.fiber = new Fiber({
            activeCoroutine = state;
            scope (exit) activeCoroutine = null;
            try
            {
                auto result = invokeFunctionValue(state.entryFunction, state.pendingArgs.dup);
                state.returnValues = [result];
            }
            catch (Exception error)
            {
                state.failed = true;
                state.errorMessage = error.msg;
            }
            state.dead = true;
        });

        auto id = nextCoroutineId++;
        coroutines[id] = state;

        Value[string] handle;
        handle["__coid"] = Value.from(cast(long) id);
        return Value.from(handle);
    }

    private CoroutineState requireCoroutineState(Value handle)
    {
        enforce(handle.kind == ValueKind.table, "Coroutine handle must be a table");
        auto idValue = "__coid" in handle.tableValue;
        enforce(idValue !is null, "Invalid coroutine handle");
        auto id = cast(size_t) idValue.toInt();
        auto state = id in coroutines;
        enforce(state !is null, "Unknown coroutine handle");
        return *state;
    }

    private Value resumeCoroutine(Value handle, Value[] args)
    {
        auto state = requireCoroutineState(handle);
        if (state.dead)
        {
            auto message = state.failed && state.errorMessage.length > 0
                ? state.errorMessage
                : "cannot resume dead coroutine";
            return Value.from([Value.from(false), Value.from(message)]);
        }

        state.pendingArgs = args.dup;
        state.yieldedValues.length = 0;
        state.started = true;
        state.fiber.call();

        if (state.failed)
        {
            state.dead = true;
            return Value.from([Value.from(false), Value.from(state.errorMessage)]);
        }

        if (state.dead)
        {
            Value[] done = [Value.from(true)];
            done ~= state.returnValues;
            return Value.from(done);
        }

        Value[] yielded = [Value.from(true)];
        yielded ~= state.yieldedValues;
        return Value.from(yielded);
    }

    private Value coroutineStatus(Value handle)
    {
        auto state = requireCoroutineState(handle);
        if (state.dead)
        {
            return Value.from("dead");
        }
        if (!state.started)
        {
            return Value.from("suspended");
        }
        return Value.from(state.fiber.state == Fiber.State.HOLD ? "suspended" : "running");
    }

    private Value currentCoroutineHandle()
    {
        if (activeCoroutine is null)
        {
            return Value.nullValue();
        }
        foreach (id, state; coroutines)
        {
            if (state is activeCoroutine)
            {
                Value[string] handle;
                handle["__coid"] = Value.from(cast(long) id);
                return Value.from(handle);
            }
        }
        return Value.nullValue();
    }

    private void installStandardLibraries()
    {
        bindNative("error", (scope const(Value)[] args) {
            enforce(args.length >= 1, "error(message) expects at least one argument");
            string message = stringify(cast(Value) args[0]);
            if (args.length > 1)
            {
                message = format("%s (level: %s)", message, (cast(Value) args[1]).toHostString());
            }
            enforce(false, message);
            return Value.nullValue();
        });
        bindNative("typeof", (scope const(Value)[] args) {
            return typeOfValue(args);
        });
        bindNative("typeinfo", (scope const(Value)[] args) {
            return typeOfValue(args);
        });
        bindNative("length", (scope const(Value)[] args) {
            return measureLengthValue(args);
        });
        bindNative("len", (scope const(Value)[] args) {
            return measureLengthValue(args);
        });
        bindNative("rawget", (scope const(Value)[] args) {
            enforce(args.length == 2, "rawget(table, key) expects two arguments");
            enforce(args[0].kind == ValueKind.table, "rawget first argument must be table");
            auto key = (cast(Value) args[1]).toHostString();
            if (auto found = key in args[0].tableValue)
            {
                return cast(Value) *found;
            }
            return Value.nullValue();
        });
        bindNative("rawset", (scope const(Value)[] args) {
            enforce(args.length == 3, "rawset(table, key, value) expects three arguments");
            enforce(args[0].kind == ValueKind.table, "rawset first argument must be table");
            auto table = cast(Value) args[0];
            table.tableValue[(cast(Value) args[1]).toHostString()] = cast(Value) args[2];
            return table;
        });
        bindNative("setmetatable", (scope const(Value)[] args) {
            enforce(args.length == 2, "setmetatable(table, meta) expects two arguments");
            enforce(args[0].kind == ValueKind.table, "setmetatable first argument must be table");
            enforce(args[1].kind == ValueKind.table || args[1].kind == ValueKind.null_,
                "setmetatable second argument must be table or null");
            auto table = cast(Value) args[0];
            if (args[1].kind == ValueKind.null_)
            {
                table.tableValue.remove("__meta");
            }
            else
            {
                table.tableValue["__meta"] = cast(Value) args[1];
            }
            return table;
        });
        bindNative("setmetatableWithType", (scope const(Value)[] args) {
            return setMetatableWithType(args);
        });
        bindNative("getmetatable", (scope const(Value)[] args) {
            enforce(args.length == 1, "getmetatable(table) expects one argument");
            enforce(args[0].kind == ValueKind.table, "getmetatable argument must be table");
            if (auto meta = "__meta" in args[0].tableValue)
            {
                return cast(Value) *meta;
            }
            return Value.nullValue();
        });
        bindNative("pcall", (scope const(Value)[] args) {
            enforce(args.length >= 1, "pcall(fn, ...) expects at least one argument");
            enforce(args[0].kind == ValueKind.function_, "pcall first argument must be function");
            try
            {
                Value[] callArgs;
                foreach (arg; args[1 .. $])
                {
                    callArgs ~= cast(Value) arg;
                }
                auto result = invokeFunctionValue(cast(Value) args[0], callArgs);
                return Value.from([Value.from(true), result]);
            }
            catch (Exception error)
            {
                return Value.from([Value.from(false), Value.from(error.msg)]);
            }
        });
        bindNative("xpcall", (scope const(Value)[] args) {
            enforce(args.length >= 2, "xpcall(fn, errHandler, ...) expects at least two arguments");
            enforce(args[0].kind == ValueKind.function_, "xpcall first argument must be function");
            enforce(args[1].kind == ValueKind.function_, "xpcall second argument must be function");
            try
            {
                Value[] callArgs;
                foreach (arg; args[2 .. $])
                {
                    callArgs ~= cast(Value) arg;
                }
                auto result = invokeFunctionValue(cast(Value) args[0], callArgs);
                return Value.from([Value.from(true), result]);
            }
            catch (Exception error)
            {
                auto handled = invokeFunctionValue(cast(Value) args[1], [Value.from(error.msg)]);
                return Value.from([Value.from(false), handled]);
            }
        });
        bindNative("map", (scope const(Value)[] args) {
            return mapValue(args);
        });
        bindNative("filter", (scope const(Value)[] args) {
            return filterValue(args);
        });

        Value[string] coroutineLib;
        coroutineLib["create"] = Value.fromFunction(new NativeCallable("coroutine.create", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.create(fn) expects one argument");
            return createCoroutine(cast(Value) args[0]);
        }));
        coroutineLib["resume"] = Value.fromFunction(new NativeCallable("coroutine.resume", (scope const(Value)[] args) {
            enforce(args.length >= 1, "coroutine.resume(co, ...) expects at least one argument");
            Value[] resumeArgs;
            foreach (arg; args[1 .. $])
            {
                resumeArgs ~= cast(Value) arg;
            }
            return resumeCoroutine(cast(Value) args[0], resumeArgs);
        }));
        coroutineLib["status"] = Value.fromFunction(new NativeCallable("coroutine.status", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.status(co) expects one argument");
            return coroutineStatus(cast(Value) args[0]);
        }));
        coroutineLib["running"] = Value.fromFunction(new NativeCallable("coroutine.running", (scope const(Value)[] args) {
            enforce(args.length == 0, "coroutine.running() takes no arguments");
            return currentCoroutineHandle();
        }));
        coroutineLib["isyieldable"] = Value.fromFunction(new NativeCallable("coroutine.isyieldable", (scope const(Value)[] args) {
            enforce(args.length == 0, "coroutine.isyieldable() takes no arguments");
            return Value.from(activeCoroutine !is null);
        }));
        coroutineLib["wrap"] = Value.fromFunction(new NativeCallable("coroutine.wrap", (scope const(Value)[] args) {
            enforce(args.length == 1, "coroutine.wrap(fn) expects one argument");
            auto handle = createCoroutine(cast(Value) args[0]);
            return Value.fromFunction(new NativeCallable("coroutine.wrapped", (scope const(Value)[] callArgs) {
                Value[] resumeArgs;
                foreach (arg; callArgs)
                {
                    resumeArgs ~= cast(Value) arg;
                }
                auto resumed = resumeCoroutine(handle, resumeArgs);
                enforce(resumed.kind == ValueKind.array && resumed.arrayValue.length >= 1,
                    "coroutine.wrap resume failed");
                if (!resumed.arrayValue[0].truthy())
                {
                    enforce(false, resumed.arrayValue.length > 1
                        ? resumed.arrayValue[1].toHostString()
                        : "coroutine.wrap failure");
                }
                return resumed.arrayValue.length > 1 ? resumed.arrayValue[1] : Value.nullValue();
            }));
        }));
        globals.define("coroutine", Value.from(coroutineLib));

        Value[string] stringLib;
        stringLib["len"] = Value.fromFunction(new NativeCallable("string.len", (scope const(Value)[] args) {
            return measureLengthValue(args);
        }));
        stringLib["upper"] = Value.fromFunction(new NativeCallable("string.upper", (scope const(Value)[] args) {
            enforce(args.length == 1, "string.upper(value) expects one argument");
            return Value.from(args[0].toHostString().toUpper().to!string);
        }));
        stringLib["lower"] = Value.fromFunction(new NativeCallable("string.lower", (scope const(Value)[] args) {
            enforce(args.length == 1, "string.lower(value) expects one argument");
            return Value.from(args[0].toHostString().toLower().to!string);
        }));
        stringLib["trim"] = Value.fromFunction(new NativeCallable("string.trim", (scope const(Value)[] args) {
            import std.string : strip;
            enforce(args.length == 1, "string.trim(value) expects one argument");
            return Value.from(args[0].toHostString().strip());
        }));
        stringLib["contains"] = Value.fromFunction(new NativeCallable("string.contains", (scope const(Value)[] args) {
            enforce(args.length == 2, "string.contains(value, needle) expects two arguments");
            return Value.from(args[0].toHostString().canFind(args[1].toHostString()));
        }));
        stringLib["replace"] = Value.fromFunction(new NativeCallable("string.replace", (scope const(Value)[] args) {
            enforce(args.length == 3, "string.replace(value, from, to) expects three arguments");
            return Value.from(args[0].toHostString().replace(args[1].toHostString(), args[2].toHostString()));
        }));
        globals.define("string", Value.from(stringLib));

        Value[string] mathLib;
        mathLib["abs"] = Value.fromFunction(new NativeCallable("math.abs", (scope const(Value)[] args) {
            enforce(args.length == 1, "math.abs(value) expects one argument");
            auto value = args[0].toFloat();
            return Value.from(value < 0 ? -value : value);
        }));
        mathLib["floor"] = Value.fromFunction(new NativeCallable("math.floor", (scope const(Value)[] args) {
            enforce(args.length == 1, "math.floor(value) expects one argument");
            return Value.from(cast(long) floor(args[0].toFloat()));
        }));
        mathLib["min"] = Value.fromFunction(new NativeCallable("math.min", (scope const(Value)[] args) {
            enforce(args.length >= 1, "math.min(value, ...) expects at least one argument");
            double minimum = args[0].toFloat();
            foreach (arg; args[1 .. $])
            {
                auto candidate = arg.toFloat();
                if (candidate < minimum)
                {
                    minimum = candidate;
                }
            }
            return Value.from(minimum);
        }));
        mathLib["max"] = Value.fromFunction(new NativeCallable("math.max", (scope const(Value)[] args) {
            enforce(args.length >= 1, "math.max(value, ...) expects at least one argument");
            double maximum = args[0].toFloat();
            foreach (arg; args[1 .. $])
            {
                auto candidate = arg.toFloat();
                if (candidate > maximum)
                {
                    maximum = candidate;
                }
            }
            return Value.from(maximum);
        }));
        globals.define("math", Value.from(mathLib));

        Value[string] tableLib;
        tableLib["len"] = Value.fromFunction(new NativeCallable("table.len", (scope const(Value)[] args) {
            return measureLengthValue(args);
        }));
        tableLib["length"] = tableLib["len"];
        tableLib["keys"] = Value.fromFunction(new NativeCallable("table.keys", (scope const(Value)[] args) {
            enforce(args.length == 1, "table.keys(value) expects one argument");
            enforce(args[0].kind == ValueKind.table, "table.keys supports table values only");
            Value[] keys;
            foreach (key; args[0].tableValue.keys)
            {
                keys ~= tableKeyToScriptValue(key);
            }
            return Value.from(keys);
        }));
        tableLib["map"] = Value.fromFunction(new NativeCallable("table.map", (scope const(Value)[] args) {
            return mapValue(args);
        }));
        tableLib["filter"] = Value.fromFunction(new NativeCallable("table.filter", (scope const(Value)[] args) {
            return filterValue(args);
        }));
        globals.define("table", Value.from(tableLib));

        Value[string] ioLib;
        ioLib["exists"] = Value.fromFunction(new NativeCallable("io.exists", (scope const(Value)[] args) {
            enforce(args.length == 1, "io.exists(path) expects one argument");
            return Value.from(exists(args[0].toHostString()));
        }));
        ioLib["readFile"] = Value.fromFunction(new NativeCallable("io.readFile", (scope const(Value)[] args) {
            enforce(args.length == 1, "io.readFile(path) expects one argument");
            auto path = args[0].toHostString();
            enforce(exists(path), format("File not found: %s", path));
            return Value.from(readText(path));
        }));
        globals.define("io", Value.from(ioLib));

        Value[string] osLib;
        osLib["clock"] = Value.fromFunction(new NativeCallable("os.clock", (scope const(Value)[] args) {
            enforce(args.length == 0, "os.clock() takes no arguments");
            return Value.from(Clock.currTime.toUnixTime());
        }));
        osLib["getenv"] = Value.fromFunction(new NativeCallable("os.getenv", (scope const(Value)[] args) {
            import std.process : environment;
            enforce(args.length == 1, "os.getenv(name) expects one argument");
            auto name = args[0].toHostString();
            return Value.from(environment.get(name, ""));
        }));
        globals.define("os", Value.from(osLib));

        Value[string] utf8Lib;
        utf8Lib["len"] = Value.fromFunction(new NativeCallable("utf8.len", (scope const(Value)[] args) {
            enforce(args.length == 1, "utf8.len(value) expects one argument");
            long count = 0;
            foreach (_; byDchar(args[0].toHostString()))
            {
                ++count;
            }
            return Value.from(count);
        }));
        globals.define("utf8", Value.from(utf8Lib));

        Value[string] debugLib;
        debugLib["type"] = Value.fromFunction(new NativeCallable("debug.type", (scope const(Value)[] args) {
            enforce(args.length == 1, "debug.type(value) expects one argument");
            return Value.from(args[0].kind.to!string);
        }));
        debugLib["traceback"] = Value.fromFunction(new NativeCallable("debug.traceback", (scope const(Value)[] args) {
            enforce(args.length == 0, "debug.traceback() takes no arguments");
            return Value.from(callStack.join("\n"));
        }));
        globals.define("debug", Value.from(debugLib));

        Value[string] timeLib;
        timeLib["nowUnix"] = Value.fromFunction(new NativeCallable("time.nowUnix", (scope const(Value)[] args) {
            enforce(args.length == 0, "time.nowUnix() takes no arguments");
            import core.stdc.time : time;
            return Value.from(cast(long) time(null));
        }));
        globals.define("time", Value.from(timeLib));

        Value[string] jsonLib;
        jsonLib["encode"] = Value.fromFunction(new NativeCallable("json.encode", (scope const(Value)[] args) {
            enforce(args.length == 1, "json.encode(value) expects one argument");
            return Value.from(args[0].toScriptLiteral());
        }));
        globals.define("json", Value.from(jsonLib));
        globals.define("_ENV", Value.fromFunction(new NativeCallable("_ENV", (scope const(Value)[] args) {
            enforce(args.length == 1, "_ENV(name) expects one argument");
            return globals.get(args[0].toHostString());
        })));
    }
}

private final class BindTypeEnemy
{
    int hp;
    string role;

    this()
    {
        hp = 10;
        role = "grunt";
    }

    string shout(string suffix)
    {
        return role ~ ":" ~ hp.to!string ~ suffix;
    }
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let sum = 0;
        for (let i = 0; i < 6; i = i + 1) {
            if (i == 4) {
                continue;
            }
            sum = sum + i;
        }
        return sum;
    });
    assert(result.toInt() == 11);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let total = 0;
        foreach (item; [1, 2, 3, 4, 5]) {
            if (item > 3) {
                break;
            }
            total = total + item;
        }

        switch (total) {
            case 6:
                total = total + 10;
                break;
            default:
                total = total + 99;
        }

        return total == 16 ? total : -1;
    });
    assert(result.toInt() == 16);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let indexTotal = 0;
        let valueTotal = 0;
        foreach (idx, item; [3, 5, 7]) {
            indexTotal = indexTotal + idx;
            valueTotal = valueTotal + item;
        }

        let seen = 0;
        foreach (key, value; { a = 2, b = 4 }) {
            if (key == "a" || key == "b") {
                seen = seen + value;
            }
        }

        return indexTotal + valueTotal + seen;
    });

    assert(result.toInt() == 24);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let fallback = { hp = 9 };
        let sink = {};
        let obj = {
            __index = fallback,
            __newindex = sink,
            __call = fn(self, x) { return self.hp + x; },
            __len = fn(self) { return 77; }
        };

        obj.mp = 5;
        let hp = obj.hp;
        let mp = obj.__newindex.mp;
        let callValue = obj(3);
        return hp + mp + callValue + table.len(obj);
    });

    assert(result.toInt() == 103);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let touched = 0;

        fn mark() {
            touched = touched + 1;
            return true;
        }

        let a = false && mark();
        let b = true || mark();
        let c = true && mark();
        let d = false || mark();

        if (!a && b && c && d) {
            return touched;
        }
        return -1;
    });

    assert(result.toInt() == 2);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        fn split(x) {
            return x, x + 1, x + 2;
        }

        let a, b, c = split(10);
        a, b = split(2);
        return a + b + c;
    });

    assert(result.toInt() == 17);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        fn total(head, tail...) {
            let sum = head;
            foreach (item; tail) {
                sum = sum + item;
            }
            return sum;
        }

        return total(1, 2, 3, 4);
    });

    assert(result.toInt() == 10);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        fn decorate(self, suffix) {
            return { value = self.value ~ suffix };
        }

        let node = {
            value = "A",
            opBinary~ = fn(self, rhs) {
                return { value = self.value ~ rhs.value };
            }
        };

        let combined = node ~ { value = "B" };
        let chained = combined.decorate("C");
        return chained.value;
    });

    assert(result.toHostString() == "ABC");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.runSafe(q{
        fn outer() {
            return missing();
        }

        fn missing() {
            return undefinedValue;
        }

        return outer();
    });

    assert(!result.ok);
    assert(result.errorMessage.length > 0);
    assert(result.stackTrace.length > 0);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.registerModule("combat", q{
        let stats = { base = 40 };
        return stats;
    });

    auto result = engine.run(q{
        let combat = require("combat");
        let cached = require("combat");
        let text = string.upper("ok");
        return combat.base + table.len(cached) + math.abs(-1) + string.len(text);
    });

    assert(result.toInt() == 44);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.registerModule("combat.rules", q{
        export let base = 7;
        export fn add(x) {
            return x + base;
        }
    });

    auto result = engine.run(q{
        import combat.rules as rules;
        return rules.add(5);
    });

    assert(result.toInt() == 12);
}

unittest
{
    struct Stats
    {
        int hp;
        int mp;

        int total() const
        {
            return hp + mp;
        }

        int withBonus(int bonus) const
        {
            return hp + mp + bonus;
        }
    }

    final class Player
    {
        string name;

        this(string name)
        {
            this.name = name;
        }

        string greet(string suffix)
        {
            return name ~ suffix;
        }
    }

    auto engine = new ScriptEngine();
    auto stats = Stats(12, 8);
    auto player = new Player("mage");

    engine.bind("stats", Value.reflect(stats));
    engine.bind("player", Value.reflect(player));

    auto result = engine.run(q{
        player.name = "archmage";
        return stats.total() + stats.withBonus(5) + string.len(player.greet("!"));
    });

    assert(result.toInt() == 54);
    assert(player.name == "archmage");
    assert(stats.hp == 12);
}

unittest
{
    struct StatsAuto
    {
        int hp;
        int mp;
    }

    final class PlayerAuto
    {
        int level;
    }

    auto engine = new ScriptEngine();
    auto stats = StatsAuto(10, 5);
    auto player = new PlayerAuto();
    player.level = 3;

    engine.bindAuto("base", 7);
    engine.bindAuto("stats", stats);
    engine.bindAuto("player", player);

    auto result = engine.run(q{
        player.level = player.level + 2;
        stats.hp = 99;
        return base + stats.hp + player.level;
    });

    assert(result.toInt() == 111);
    assert(stats.hp == 10);
    assert(player.level == 5);
}

unittest
{
    final class Enemy
    {
        int hp;
    }

    auto engine = new ScriptEngine();
    auto enemy = new Enemy();
    enemy.hp = 40;
    engine["base"] = 2;
    engine["enemy"] = enemy;

    auto result = engine.run(q{
        enemy.hp = enemy.hp + base;
        return enemy.hp;
    });

    assert(result.toInt() == 42);
    assert(engine["base"].toInt() == 2);
    assert(enemy.hp == 42);
}

unittest
{
    struct StatsTemplate
    {
        int hp;
        int mp;
    }

    auto engine = new ScriptEngine();
    engine.bindType!StatsTemplate("StatsTemplate");

    auto result = engine.run(q{
        let s = StatsTemplate.new({ hp = 11, mp = 7 });
        let infoS = typeinfo(StatsTemplate);
        return s.hp + s.mp + length(infoS.chain);
    });

    assert(result.toInt() == 19);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.bindType!BindTypeEnemy("BindTypeEnemy");

    auto result = engine.run(q{
        let enemy = BindTypeEnemy({ hp = 42, role = "boss" });
        let text = enemy.shout("!");
        let info = typeinfo(enemy);
        if (text != "boss:42!") {
            return -10;
        }
        if (length(info.chain) < 1) {
            return -20;
        }
        return length(info.chain);
    });

    assert(result.toInt() >= 1);
}

unittest
{
    struct Stats
    {
        int hp;
        int mp;
    }

    auto engine = new ScriptEngine();
    auto stats = Stats(12, 8);
    engine.bind("stats", Value.reflect(stats));

    auto result = engine.run(q{
        stats.hp = 77;
        return stats.hp;
    });

    assert(result.toInt() == 77);
    assert(stats.hp == 12);
}

unittest
{
    final class Gauge
    {
        private int current;

        void set(int value)
        {
            current = value;
        }

        int read() const
        {
            return current;
        }
    }

    auto engine = new ScriptEngine();
    auto gauge = new Gauge();
    engine.bind("gauge", Value.reflect(gauge));

    auto result = engine.run(q{
        gauge.set = 41;
        gauge.set = gauge.read + 1;
        return gauge.read;
    });

    assert(result.toInt() == 42);
}

unittest
{
    auto engine = new ScriptEngine();

    auto result = engine.run(q{
        let obj = {
            value = 0,
            get = fn() { return this.value; },
            set = fn(v) { this.value = v; }
        };
        obj.set = 5;
        obj.set = obj.get + 2;
        return obj.get + obj.value;
    });

    assert(result.toInt() == 14);
}

unittest
{
    auto engine = new ScriptEngine();

    auto result = engine.run(q{
        let point = {
            x = 3,
            move = fn(delta) {
                this.x = this.x + delta;
                return this.x;
            }
        };
        return point.move(4);
    });

    assert(result.toInt() == 7);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.load(q{
        fn add(a, b) {
            return a + b;
        }
    });

    auto result = engine.call("add", [Value.from(40), Value.from(2)]);
    assert(result.toInt() == 42);
}

unittest
{
    auto engine = new ScriptEngine();
    immutable scriptPath = "__dua_runtime_file_test.dua";
    scope(exit)
    {
        if (exists(scriptPath))
        {
            remove(scriptPath);
        }
    }

    write(scriptPath, q{
        fn add(a, b) {
            return a + b;
        }
        return add(10, 32);
    });

    auto runResult = engine.runFile(scriptPath);
    assert(runResult.toInt() == 42);

    write(scriptPath, q{
        fn mul(a, b) {
            return a * b;
        }
    });
    engine.loadFile(scriptPath);
    assert(engine.call("mul", [Value.from(6), Value.from(7)]).toInt() == 42);
}

unittest
{
    auto engine = new ScriptEngine();
    immutable missingPath = "__dua_missing_file_test.dua";
    if (exists(missingPath))
    {
        remove(missingPath);
    }

    auto runOutcome = engine.runFileSafe(missingPath);
    assert(!runOutcome.ok);
    assert(runOutcome.errorMessage.length > 0);

    auto loadOutcome = engine.loadFileSafe(missingPath);
    assert(!loadOutcome.ok);
    assert(loadOutcome.errorMessage.length > 0);
}

unittest
{
    auto engine = new ScriptEngine();
    engine.load(q{
        fn makeCounter(start) {
            let value = start;
            return fn(step) {
                value = value + step;
                return value;
            };
        }

        let counter = makeCounter(10);
    });

    auto counter = engine.getGlobal("counter");
    assert(counter.kind == ValueKind.function_);
    auto next = counter.functionValue.invoke([Value.from(5)]);
    assert(next.toInt() == 15);
}

unittest
{
    struct Settings
    {
        int volume;
        bool muted;
    }

    Value[string] table;
    table["volume"] = Value.from(15);
    table["muted"] = Value.from(true);
    auto value = Value.from(table);

    auto settings = value.to!Settings();
    assert(settings.volume == 15);
    assert(settings.muted);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let ok, value = pcall(fn() { return 9; });
        let failed, err = pcall(fn() { return missingValue; });
        let xok, xval = xpcall(fn() { return nope; }, fn(msg) { return "handled"; });
        if (ok && !failed && !xok) {
            return value + string.len(err) + string.len(xval);
        }
        return -1;
    });

    assert(result.toInt() > 9);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let t = {};
        t = setmetatable(t, { __index = { hp = 30 } });
        return t.hp + table.len(getmetatable(t));
    });
    assert(result.toInt() == 31);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let info = typeof({ hp = 1 });
        if (info.kind != "table") {
            return -10;
        }
        if (length(info.chain) != 0) {
            return -20;
        }
        if (length(info) != 2) {
            return -30;
        }
        return 0;
    });
    assert(result.toInt() == 0);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let obj = {};
        obj = setmetatableWithType(obj, { __index = { hp = 10 } }, "Enemy", "Actor");
        let info = typeinfo(obj);
        if (obj.hp != 10) {
            return -10;
        }
        if (length(info.chain) != 2) {
            return -20;
        }
        if (info.chain[0] != "Enemy") {
            return -30;
        }
        if (info.chain[1] != "Actor") {
            return -35;
        }
        return length(info.chain);
    });
    assert(result.toInt() == 2);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let v = 10 & 3;
        v = v + (8 >> 1);
        v = v + (1 << 3);
        v = v + (6 ^ 3);
        v = v + (4 | 1);
        return v;
    });
    assert(result.toInt() == 24);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let key = "name";
        let tbl = { [key] = "mage", 7, 8, fixed = 1 };
        return tbl.name ~ ":" ~ tbl[0] ~ ":" ~ tbl[1] ~ ":" ~ tbl.fixed;
    });
    assert(result.toHostString() == "mage:7:8:1");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let tbl = { 11, 22, name = "mage" };
        let foundZero = false;
        foreach (k, v; tbl) {
            if (k == 0 && v == 11) { foundZero = true; }
        }
        return foundZero;
    });
    assert(result.truthy());
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(
        "let a, b, c = #[1, 2, 3];\n"
        ~ "let tbl = #{ hp = 7, mp = 5 };\n"
        ~ "return a + c + tbl.hp + tbl.mp;\n");
    assert(result.toInt() == 16);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let co = coroutine.create(fn(start) {
            let current = start;
            yield current;
            current = current + 1;
            yield current;
            return current + 1;
        });

        let ok1, v1 = coroutine.resume(co, 5);
        let ok2, v2 = coroutine.resume(co);
        let ok3, v3 = coroutine.resume(co);
        let status = coroutine.status(co);

        if (ok1 && ok2 && ok3 && status == "dead") {
            return v1 + v2 + v3;
        }
        return -1;
    });

    assert(result.toInt() == 18);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let text = string.trim("  Dua  ");
        if (!string.contains(text, "ua")) {
            return -1;
        }
        return string.replace(text, "ua", "UA");
    });
    assert(result.toHostString() == "DUA");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let replaced = string.replace("a-b-c", "-", ":");
        return string.len(replaced) + math.min(6, 2, 9) + math.max(1, 5, 3);
    });
    assert(result.toInt() == 12);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let addOne = fn x => x + 1;
        let twice = fn(v) => v * 2;
        let composed = twice(addOne(20));
        let pair = fn(a, b) => a + b;
        return composed + pair(1, 2);
    });
    assert(result.toInt() == 45);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let box = { v = 0 };
        let sink = fn(x) :> rawset(box, "v", x * 3);
        let out = sink(7);
        if (box.v == 21 && out == null) {
            return 1;
        }
        return 0;
    });
    assert(result.toInt() == 1);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let ev0 = filter(map([1, 2, 3, 4, 5], fn(x) => x * 2), fn(x) => x % 4 == 0)[0];
        let ev1 = filter(map([1, 2, 3, 4, 5], fn(x) => x * 2), fn(x) => x % 4 == 0)[1];

        let stats = { hp = 10, mp = 7, sp = 4 };
        let boosted = table.map(stats, fn(v, k) => v + 1);
        let picked = table.filter(boosted, fn(v, k) => v >= 8);

        return ev0 + ev1 + picked.hp + picked.mp + table.len(picked);
    });
    assert(result.toInt() == 33);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        // comment
        /+ outer
            /+ inner +/
        +/
        return length([10, 20, 30, 40][1 .. $]);
    });
    assert(result.toInt() == 3);
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let name = "Dua";
        let level = 7;
        return i"Hello, $(name)! Lv.$(level)";
    });
    assert(result.toHostString() == "Hello, Dua! Lv.7");
}

unittest
{
    auto engine = new ScriptEngine();
    auto result = engine.run(q{
        let table = { nested = { value = 3 } };
        return i"$$score=$(1 + 2, table.nested.value)";
    });
    assert(result.toHostString() == "$score=33");
}
