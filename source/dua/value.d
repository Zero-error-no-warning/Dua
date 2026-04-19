module dua.value;

import std.algorithm : map;
import std.array : array;
import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.string : join;
import std.traits : BaseClassesTuple, KeyType, Parameters, ReturnType, isAggregateType, isAssociativeArray, isCallable, isDynamicArray, isFloatingPoint, isIntegral, isSomeString;
import std.typecons : Tuple;

abstract class CallableValue
{
    string debugName;

    this(string debugName)
    {
        this.debugName = debugName;
    }

    abstract Value invoke(Value[] args);

    size_t expectedArity() const
    {
        return size_t.max;
    }

    size_t minimumArity() const
    {
        auto arity = expectedArity();
        return arity == size_t.max ? 0 : arity;
    }
}

final class ReflectedCallable : CallableValue
{
    private Value delegate(Value[] args) invoker;
    private size_t arity;

    this(string debugName, size_t arity, Value delegate(Value[] args) invoker)
    {
        super(debugName);
        this.arity = arity;
        this.invoker = invoker;
    }

    override Value invoke(Value[] args)
    {
        return invoker(args);
    }

    override size_t expectedArity() const
    {
        return arity;
    }

}

enum ValueKind
{
    null_,
    integer,
    floating,
    boolean,
    string_,
    array,
    table,
    function_,
    native
}

enum string internalFieldGetterPrefix = "__dua_get_";
enum string internalFieldSetterPrefix = "__dua_set_";

struct Value
{
    ValueKind kind = ValueKind.null_;
    long integerValue;
    double floatingValue;
    bool booleanValue;
    string stringValue;
    Value[] arrayValue;
    Value[string] tableValue;
    CallableValue functionValue;
    string nativeTypeName;
    string nativeDisplay;

    static Value nullValue()
    {
        return Value();
    }

    static Value from(long value)
    {
        Value result;
        result.kind = ValueKind.integer;
        result.integerValue = value;
        return result;
    }

    static Value from(int value)
    {
        return from(cast(long) value);
    }

    static Value from(double value)
    {
        Value result;
        result.kind = ValueKind.floating;
        result.floatingValue = value;
        return result;
    }

    static Value from(bool value)
    {
        Value result;
        result.kind = ValueKind.boolean;
        result.booleanValue = value;
        return result;
    }

    static Value from(string value)
    {
        Value result;
        result.kind = ValueKind.string_;
        result.stringValue = value;
        return result;
    }

    static Value from(Value[] values)
    {
        Value result;
        result.kind = ValueKind.array;
        result.arrayValue = values.dup;
        return result;
    }

    static Value from(Value[string] entries)
    {
        Value result;
        result.kind = ValueKind.table;
        result.tableValue = entries.dup;
        return result;
    }

    static Value fromFunction(CallableValue callable)
    {
        Value result;
        result.kind = ValueKind.function_;
        result.functionValue = callable;
        return result;
    }

    static Value native(T)(T value)
    {
        Value result;
        result.kind = ValueKind.native;
        result.nativeTypeName = T.stringof;
        result.nativeDisplay = to!string(value);
        return result;
    }

    static Value from(T)(T values)
        if (isDynamicArray!T && !isSomeString!T)
    {
        return Value.from(values.map!(item => convertToValue(item)).array);
    }

    static Value from(T)(T entries)
        if (isAssociativeArray!T && isSomeString!(KeyType!T))
    {
        Value[string] converted;
        foreach (key, value; entries)
        {
            converted[key] = convertToValue(value);
        }
        return Value.from(converted);
    }

    static Value reflect(T)(auto ref T value)
        if (isAggregateType!T)
    {
        Value[string] converted;
        static foreach (memberName; __traits(allMembers, T))
        {{
            static if (memberName != "this" && memberName != "__ctor" && memberName != "Monitor" && memberName != "factory")
            {
                static if (__traits(compiles, mixin("value." ~ memberName)))
                {
                    static if (__traits(compiles, mixin("&value." ~ memberName)))
                    {
                        alias Member = typeof(mixin("&value." ~ memberName));
                        static if (isCallable!Member)
                        {
                            converted[memberName] = Value.fromFunction(
                                makeReflectedCallable(T.stringof ~ "." ~ memberName, mixin("&value." ~ memberName)));
                        }
                        else
                        {
                            converted[memberName] = convertToValue(mixin("value." ~ memberName));
                            static if (is(T == class))
                            {
                                converted[internalFieldGetterPrefix ~ memberName] = Value.fromFunction(
                                    new ReflectedCallable(T.stringof ~ "." ~ memberName ~ ".getter", 0, (Value[] args) {
                                    return convertToValue(mixin("value." ~ memberName));
                                }));
                                converted[internalFieldSetterPrefix ~ memberName] = Value.fromFunction(
                                    new ReflectedCallable(T.stringof ~ "." ~ memberName ~ ".setter", 1, (Value[] args) {
                                    alias FieldType = typeof(mixin("value." ~ memberName));
                                    mixin("value." ~ memberName) = convertFromValue!FieldType(args[0]);
                                    return Value.nullValue();
                                }));
                            }
                        }
                    }
                    else
                    {
                        converted[memberName] = convertToValue(mixin("value." ~ memberName));
                        static if (is(T == class))
                        {
                            converted[internalFieldGetterPrefix ~ memberName] = Value.fromFunction(
                                new ReflectedCallable(T.stringof ~ "." ~ memberName ~ ".getter", 0, (Value[] args) {
                                return convertToValue(mixin("value." ~ memberName));
                            }));
                            converted[internalFieldSetterPrefix ~ memberName] = Value.fromFunction(
                                new ReflectedCallable(T.stringof ~ "." ~ memberName ~ ".setter", 1, (Value[] args) {
                                alias FieldType = typeof(mixin("value." ~ memberName));
                                mixin("value." ~ memberName) = convertFromValue!FieldType(args[0]);
                                return Value.nullValue();
                            }));
                        }
                    }
                }
            }
        }}
        static if (is(T == class))
        {
            Value[] typeChain;
            typeChain ~= Value.from(T.stringof);
            static foreach (Base; BaseClassesTuple!T)
            {
                typeChain ~= Value.from(Base.stringof);
            }
            converted["__typechain"] = Value.from(typeChain);
        }
        return Value.from(converted);
    }

    bool isNumber() const
    {
        return kind == ValueKind.integer || kind == ValueKind.floating;
    }

    double toFloat() const
    {
        switch (kind)
        {
            case ValueKind.integer:
                return integerValue;
            case ValueKind.floating:
                return floatingValue;
            default:
                enforce(false, format("Expected number but got %s", kind));
                assert(0);
        }
    }

    long toInt() const
    {
        switch (kind)
        {
            case ValueKind.integer:
                return integerValue;
            case ValueKind.floating:
                return cast(long) floatingValue;
            default:
                enforce(false, format("Expected integer but got %s", kind));
                assert(0);
        }
    }

    T to(T)() const
    {
        return convertFromValue!T(this);
    }

    string toHostString() const
    {
        final switch (kind)
        {
            case ValueKind.null_:
                return "null";
            case ValueKind.integer:
                return integerValue.to!string;
            case ValueKind.floating:
                return floatingValue.to!string;
            case ValueKind.boolean:
                return booleanValue ? "true" : "false";
            case ValueKind.string_:
                return stringValue;
            case ValueKind.array:
                return "[" ~ arrayValue.map!(item => item.toHostString()).array.join(", ") ~ "]";
            case ValueKind.table:
                string[] parts;
                foreach (key, value; tableValue)
                {
                    parts ~= key ~ ": " ~ value.toHostString();
                }
                return "{" ~ parts.join(", ") ~ "}";
            case ValueKind.function_:
                return "<fn " ~ functionValue.debugName ~ ">";
            case ValueKind.native:
                return nativeTypeName ~ "(" ~ nativeDisplay ~ ")";
        }
    }

    string toScriptLiteral() const
    {
        final switch (kind)
        {
            case ValueKind.null_:
                return "null";
            case ValueKind.integer:
                return integerValue.to!string;
            case ValueKind.floating:
                return floatingValue.to!string;
            case ValueKind.boolean:
                return booleanValue ? "true" : "false";
            case ValueKind.string_:
                return '"' ~ stringValue ~ '"';
            case ValueKind.array:
                return "[" ~ arrayValue.map!(item => item.toScriptLiteral()).array.join(", ") ~ "]";
            case ValueKind.table:
                string[] parts;
                foreach (key, value; tableValue)
                {
                    parts ~= key ~ " = " ~ value.toScriptLiteral();
                }
                return "{" ~ parts.join(", ") ~ "}";
            case ValueKind.function_:
                return "<fn " ~ functionValue.debugName ~ ">";
            case ValueKind.native:
                return "<" ~ nativeTypeName ~ ":" ~ nativeDisplay ~ ">";
        }
    }

    bool truthy() const
    {
        final switch (kind)
        {
            case ValueKind.null_:
                return false;
            case ValueKind.integer:
                return integerValue != 0;
            case ValueKind.floating:
                return floatingValue != 0;
            case ValueKind.boolean:
                return booleanValue;
            case ValueKind.string_:
                return stringValue.length > 0;
            case ValueKind.array:
                return arrayValue.length > 0;
            case ValueKind.table:
                return tableValue.length > 0;
            case ValueKind.function_:
                return true;
            case ValueKind.native:
                return true;
        }
    }
}

private ReflectedCallable makeReflectedCallable(C)(string debugName, auto ref C callable)
    if (isCallable!C)
{
    alias Params = Parameters!C;
    return new ReflectedCallable(debugName, Params.length, (Value[] args) {
        enforce(args.length == Params.length,
            format("Function '%s' expected %s arguments but got %s", debugName, Params.length, args.length));

        auto converted = Tuple!Params();
        static foreach (index, Param; Params)
        {
            converted[index] = convertFromValue!Param(args[index]);
        }

        static if (is(ReturnType!C == void))
        {
            callable(converted.expand);
            return Value.nullValue();
        }
        else
        {
            return convertToValue(callable(converted.expand));
        }
    });
}

private Value convertToValue(T)(auto ref T value)
{
    static if (is(T == Value))
    {
        return value;
    }
    else static if (isSomeString!T)
    {
        return Value.from(to!string(value));
    }
    else static if (is(T == bool))
    {
        return Value.from(value);
    }
    else static if (isIntegral!T)
    {
        return Value.from(cast(long) value);
    }
    else static if (isFloatingPoint!T)
    {
        return Value.from(cast(double) value);
    }
    else static if (isDynamicArray!T && !isSomeString!T)
    {
        return Value.from(value);
    }
    else static if (isAssociativeArray!T && isSomeString!(KeyType!T))
    {
        return Value.from(value);
    }
    else static if (isAggregateType!T)
    {
        return Value.reflect(value);
    }
    else
    {
        return Value.native(value);
    }
}

private T convertFromValue(T)(const(Value) value)
{
    static if (is(T == Value))
    {
        return value;
    }
    else static if (isSomeString!T)
    {
        return to!T(value.toHostString());
    }
    else static if (is(T == bool))
    {
        return value.truthy();
    }
    else static if (isIntegral!T)
    {
        return cast(T) value.toInt();
    }
    else static if (isFloatingPoint!T)
    {
        return cast(T) value.toFloat();
    }
    else static if (isAggregateType!T && !is(T == class))
    {
        enforce(value.kind == ValueKind.table,
            format("Expected table value to convert into '%s' but got %s", T.stringof, value.kind));
        T result = T.init;
        static foreach (memberName; __traits(allMembers, T))
        {{
            static if (memberName != "this" && memberName != "__ctor" && memberName != "Monitor" && memberName != "factory")
            {
                static if (__traits(compiles, mixin("&result." ~ memberName)))
                {
                    alias Member = typeof(mixin("&result." ~ memberName));
                    static if (!isCallable!Member)
                    {
                        if (auto fieldValue = memberName in value.tableValue)
                        {
                            alias FieldType = typeof(mixin("result." ~ memberName));
                            mixin("result." ~ memberName) = convertFromValue!FieldType(*fieldValue);
                        }
                    }
                }
            }
        }}
        return result;
    }
    else
    {
        enforce(false, format("Cannot convert Value to '%s'", T.stringof));
        assert(0);
    }
}

bool valuesEqual(Value left, Value right)
{
    if (left.kind == right.kind)
    {
        final switch (left.kind)
        {
            case ValueKind.null_:
                return true;
            case ValueKind.integer:
                return left.integerValue == right.integerValue;
            case ValueKind.floating:
                return left.floatingValue == right.floatingValue;
            case ValueKind.boolean:
                return left.booleanValue == right.booleanValue;
            case ValueKind.string_:
                return left.stringValue == right.stringValue;
            case ValueKind.array:
                if (left.arrayValue.length != right.arrayValue.length)
                {
                    return false;
                }
                foreach (index, item; left.arrayValue)
                {
                    if (!valuesEqual(item, right.arrayValue[index]))
                    {
                        return false;
                    }
                }
                return true;
            case ValueKind.table:
                if (left.tableValue.length != right.tableValue.length)
                {
                    return false;
                }
                foreach (key, value; left.tableValue)
                {
                    auto other = key in right.tableValue;
                    if (other is null || !valuesEqual(value, *other))
                    {
                        return false;
                    }
                }
                return true;
            case ValueKind.function_:
                return left.functionValue is right.functionValue;
            case ValueKind.native:
                return left.nativeTypeName == right.nativeTypeName
                    && left.nativeDisplay == right.nativeDisplay;
        }
    }

    if (left.isNumber() && right.isNumber())
    {
        return left.toFloat() == right.toFloat();
    }

    return false;
}
