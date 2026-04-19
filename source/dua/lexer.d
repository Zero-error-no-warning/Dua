module dua.lexer;

import std.array : appender;
import std.ascii : isAlpha, isAlphaNum, isDigit;
import std.conv : to;
import std.exception : enforce;
import std.format : format;

struct Token
{
    TokenKind kind;
    string lexeme;
    size_t line;
    size_t column;
}

enum TokenKind
{
    eof,
    identifier,
    number,
    string_,
    keywordFn,
    keywordLet,
    keywordReturn,
    keywordIf,
    keywordElse,
    keywordWhile,
    keywordFor,
    keywordForeach,
    keywordSwitch,
    keywordCase,
    keywordDefault,
    keywordBreak,
    keywordContinue,
    keywordYield,
    keywordTrue,
    keywordFalse,
    keywordNull,
    keywordThis,
    keywordImport,
    keywordExport,
    keywordAs,
    plus,
    minus,
    star,
    slash,
    percent,
    dollar,
    tilde,
    bang,
    equal,
    equalEqual,
    bangEqual,
    less,
    lessEqual,
    greater,
    greaterEqual,
    leftParen,
    rightParen,
    leftBracket,
    rightBracket,
    leftBrace,
    rightBrace,
    comma,
    dot,
    colon,
    colonGreater,
    question,
    semicolon,
    amp,
    ampAmp,
    pipe,
    pipePipe,
    caret,
    shiftLeft,
    shiftRight,
    fatArrow,
    hashLeftBracket,
    hashLeftBrace,
    dotDot,
    ellipsis
}

Token[] lex(string source)
{
    auto tokens = appender!(Token[])();
    size_t index;
    size_t line = 1;
    size_t column = 1;

    while (index < source.length)
    {
        auto current = source[index];
        auto startColumn = column;

        if (current == ' ' || current == '\t' || current == '\r')
        {
            ++index;
            ++column;
            continue;
        }
        if (current == '\n')
        {
            ++index;
            ++line;
            column = 1;
            continue;
        }
        if (current == '/' && peek(source, index + 1) == '/')
        {
            while (index < source.length && source[index] != '\n')
            {
                ++index;
                ++column;
            }
            continue;
        }
        if (current == '/' && peek(source, index + 1) == '+')
        {
            size_t nesting = 1;
            index += 2;
            column += 2;
            while (index < source.length && nesting > 0)
            {
                if (source[index] == '\n')
                {
                    ++index;
                    ++line;
                    column = 1;
                    continue;
                }
                if (source[index] == '/' && peek(source, index + 1) == '+')
                {
                    ++nesting;
                    index += 2;
                    column += 2;
                    continue;
                }
                if (source[index] == '+' && peek(source, index + 1) == '/')
                {
                    --nesting;
                    index += 2;
                    column += 2;
                    continue;
                }
                ++index;
                ++column;
            }
            enforce(nesting == 0, format("Unterminated block comment at %s:%s", line, startColumn));
            continue;
        }
        if (isAlpha(current) || current == '_')
        {
            auto start = index;
            while (index < source.length && (isAlphaNum(source[index]) || source[index] == '_'))
            {
                ++index;
                ++column;
            }
            auto lexeme = source[start .. index];
            tokens.put(Token(keywordFor(lexeme), lexeme, line, startColumn));
            continue;
        }
        if (isDigit(current))
        {
            auto start = index;
            bool seenDot;
            while (index < source.length && (isDigit(source[index]) || (!seenDot && source[index] == '.')))
            {
                if (source[index] == '.')
                {
                    seenDot = true;
                }
                ++index;
                ++column;
            }
            tokens.put(Token(TokenKind.number, source[start .. index], line, startColumn));
            continue;
        }
        if (current == '"')
        {
            ++index;
            ++column;
            auto start = index;
            while (index < source.length && source[index] != '"')
            {
                enforce(source[index] != '\n', format("Unterminated string at %s:%s", line, startColumn));
                ++index;
                ++column;
            }
            enforce(index < source.length, format("Unterminated string at %s:%s", line, startColumn));
            auto text = source[start .. index];
            ++index;
            ++column;
            tokens.put(Token(TokenKind.string_, text, line, startColumn));
            continue;
        }

        TokenKind kind;
        string lexeme = source[index .. index + 1];
        bool consumed = true;
        switch (current)
        {
            case '+': kind = TokenKind.plus; break;
            case '-': kind = TokenKind.minus; break;
            case '*': kind = TokenKind.star; break;
            case '/': kind = TokenKind.slash; break;
            case '%': kind = TokenKind.percent; break;
            case '$': kind = TokenKind.dollar; break;
            case '~': kind = TokenKind.tilde; break;
            case '(': kind = TokenKind.leftParen; break;
            case ')': kind = TokenKind.rightParen; break;
            case '[': kind = TokenKind.leftBracket; break;
            case ']': kind = TokenKind.rightBracket; break;
            case '{': kind = TokenKind.leftBrace; break;
            case '}': kind = TokenKind.rightBrace; break;
            case ',': kind = TokenKind.comma; break;
            case '.':
                if (peek(source, index + 1) == '.' && peek(source, index + 2) == '.')
                {
                    kind = TokenKind.ellipsis;
                    lexeme = source[index .. index + 3];
                    index += 2;
                    column += 2;
                }
                else if (peek(source, index + 1) == '.')
                {
                    kind = TokenKind.dotDot;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else
                {
                    kind = TokenKind.dot;
                }
                break;
            case ':':
                if (peek(source, index + 1) == '>')
                {
                    kind = TokenKind.colonGreater;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else
                {
                    kind = TokenKind.colon;
                }
                break;
            case '?': kind = TokenKind.question; break;
            case ';': kind = TokenKind.semicolon; break;
            case '&':
                if (peek(source, index + 1) == '&')
                {
                    kind = TokenKind.ampAmp;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else
                {
                    kind = TokenKind.amp;
                }
                break;
            case '|':
                if (peek(source, index + 1) == '|')
                {
                    kind = TokenKind.pipePipe;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else
                {
                    kind = TokenKind.pipe;
                }
                break;
            case '^': kind = TokenKind.caret; break;
            case '!':
                if (peek(source, index + 1) == '=')
                {
                    kind = TokenKind.bangEqual;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else
                {
                    kind = TokenKind.bang;
                }
                break;
            case '=':
                if (peek(source, index + 1) == '>')
                {
                    kind = TokenKind.fatArrow;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else if (peek(source, index + 1) == '=')
                {
                    kind = TokenKind.equalEqual;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else
                {
                    kind = TokenKind.equal;
                }
                break;
            case '#':
                if (peek(source, index + 1) == '[')
                {
                    kind = TokenKind.hashLeftBracket;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else if (peek(source, index + 1) == '{')
                {
                    kind = TokenKind.hashLeftBrace;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else
                {
                    consumed = false;
                }
                break;
            case '<':
                if (peek(source, index + 1) == '<')
                {
                    kind = TokenKind.shiftLeft;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else if (peek(source, index + 1) == '=')
                {
                    kind = TokenKind.lessEqual;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else
                {
                    kind = TokenKind.less;
                }
                break;
            case '>':
                if (peek(source, index + 1) == '>')
                {
                    kind = TokenKind.shiftRight;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else if (peek(source, index + 1) == '=')
                {
                    kind = TokenKind.greaterEqual;
                    lexeme = source[index .. index + 2];
                    ++index;
                    ++column;
                }
                else
                {
                    kind = TokenKind.greater;
                }
                break;
            default:
                consumed = false;
                break;
        }

        enforce(consumed, format("Unexpected character '%s' at %s:%s", current.to!string, line, column));
        tokens.put(Token(kind, lexeme, line, startColumn));
        ++index;
        ++column;
    }

    tokens.put(Token(TokenKind.eof, "", line, column));
    return tokens.data;
}

private TokenKind keywordFor(string identifier)
{
    switch (identifier)
    {
        case "fn": return TokenKind.keywordFn;
        case "let": return TokenKind.keywordLet;
        case "return": return TokenKind.keywordReturn;
        case "if": return TokenKind.keywordIf;
        case "else": return TokenKind.keywordElse;
        case "while": return TokenKind.keywordWhile;
        case "for": return TokenKind.keywordFor;
        case "foreach": return TokenKind.keywordForeach;
        case "switch": return TokenKind.keywordSwitch;
        case "case": return TokenKind.keywordCase;
        case "default": return TokenKind.keywordDefault;
        case "break": return TokenKind.keywordBreak;
        case "continue": return TokenKind.keywordContinue;
        case "yield": return TokenKind.keywordYield;
        case "true": return TokenKind.keywordTrue;
        case "false": return TokenKind.keywordFalse;
        case "null": return TokenKind.keywordNull;
        case "this": return TokenKind.keywordThis;
        case "import": return TokenKind.keywordImport;
        case "export": return TokenKind.keywordExport;
        case "as": return TokenKind.keywordAs;
        default: return TokenKind.identifier;
    }
}

private char peek(string source, size_t index)
{
    return index < source.length ? source[index] : '\0';
}
