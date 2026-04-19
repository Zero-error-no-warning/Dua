module dua.parser;

import dua.ast;
import dua.lexer : Token, TokenKind;
import dua.value : Value;
import std.algorithm.searching : canFind;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.string : join, lastIndexOf;

Program parse(Token[] tokens)
{
    auto parser = Parser(tokens);
    return parser.parseProgram();
}

private struct Parser
{
    Token[] tokens;
    size_t position;

    Statement locatedStatement(Statement.Kind kind, Token token)
    {
        auto statement = new Statement(kind);
        statement.line = token.line;
        statement.column = token.column;
        return statement;
    }

    Expression locatedExpression(Expression.Kind kind, Token token)
    {
        auto expression = new Expression(kind);
        expression.line = token.line;
        expression.column = token.column;
        return expression;
    }

    Program parseProgram()
    {
        auto statements = appender!(Statement[])();
        while (!check(TokenKind.eof))
        {
            statements.put(parseStatement());
        }
        return new Program(statements.data);
    }

    Statement parseStatement()
    {
        if (match(TokenKind.keywordImport))
        {
            auto statement = locatedStatement(Statement.Kind.import_, previous());
            statement.name = parseModuleName();
            auto aliasName = lastModuleSegment(statement.name);
            if (match(TokenKind.keywordAs))
            {
                aliasName = consume(TokenKind.identifier, "Expected alias name after 'as'").lexeme;
            }
            statement.aliasName = aliasName;
            consume(TokenKind.semicolon, "Expected ';' after import statement");
            return statement;
        }

        bool exportPrefix;
        Token exportToken;
        if (match(TokenKind.keywordExport))
        {
            exportPrefix = true;
            exportToken = previous();
        }

        if (match(TokenKind.leftBrace))
        {
            enforce(!exportPrefix, "export block is not supported");
            auto statement = locatedStatement(Statement.Kind.block, previous());
            statement.body = parseBlockTail();
            return statement;
        }

        if (match(TokenKind.keywordLet))
        {
            auto statement = locatedStatement(Statement.Kind.let_, previous());
            statement.isExported = exportPrefix;
            auto names = appender!(string[])();
            names.put(consume(TokenKind.identifier, "Expected variable name after let").lexeme);
            while (match(TokenKind.comma))
            {
                names.put(consume(TokenKind.identifier, "Expected variable name after ','").lexeme);
            }
            statement.names = names.data;
            statement.name = statement.names[0];
            consume(TokenKind.equal, "Expected '=' after variable name");
            statement.expressions = parseExpressionList();
            statement.expression = statement.expressions[0];
            consume(TokenKind.semicolon, "Expected ';' after let binding");
            return statement;
        }

        if (match(TokenKind.keywordReturn))
        {
            auto statement = locatedStatement(Statement.Kind.return_, previous());
            if (!check(TokenKind.semicolon))
            {
                statement.expressions = parseExpressionList();
                statement.expression = statement.expressions[0];
            }
            consume(TokenKind.semicolon, "Expected ';' after return value");
            return statement;
        }

        if (match(TokenKind.keywordBreak))
        {
            auto statement = locatedStatement(Statement.Kind.break_, previous());
            consume(TokenKind.semicolon, "Expected ';' after break");
            return statement;
        }

        if (match(TokenKind.keywordContinue))
        {
            auto statement = locatedStatement(Statement.Kind.continue_, previous());
            consume(TokenKind.semicolon, "Expected ';' after continue");
            return statement;
        }

        if (match(TokenKind.keywordYield))
        {
            auto statement = locatedStatement(Statement.Kind.yield_, previous());
            if (!check(TokenKind.semicolon))
            {
                statement.expressions = parseExpressionList();
                statement.expression = statement.expressions[0];
            }
            consume(TokenKind.semicolon, "Expected ';' after yield");
            return statement;
        }

        if (match(TokenKind.keywordIf))
        {
            auto statement = locatedStatement(Statement.Kind.if_, previous());
            consume(TokenKind.leftParen, "Expected '(' after if");
            statement.condition = parseExpression();
            consume(TokenKind.rightParen, "Expected ')' after if condition");
            statement.body = [parseStatement()];
            if (match(TokenKind.keywordElse))
            {
                statement.elseBranch = parseStatement();
            }
            return statement;
        }

        if (match(TokenKind.keywordWhile))
        {
            auto statement = locatedStatement(Statement.Kind.while_, previous());
            consume(TokenKind.leftParen, "Expected '(' after while");
            statement.condition = parseExpression();
            consume(TokenKind.rightParen, "Expected ')' after while condition");
            statement.body = [parseStatement()];
            return statement;
        }

        if (match(TokenKind.keywordFor))
        {
            auto statement = locatedStatement(Statement.Kind.for_, previous());
            consume(TokenKind.leftParen, "Expected '(' after for");

            if (!check(TokenKind.semicolon))
            {
                if (match(TokenKind.keywordLet))
                {
                    auto init = locatedStatement(Statement.Kind.let_, previous());
                    init.name = consume(TokenKind.identifier, "Expected variable name after let").lexeme;
                    init.names = [init.name];
                    consume(TokenKind.equal, "Expected '=' after variable name");
                    init.expression = parseExpression();
                    init.expressions = [init.expression];
                    statement.init = init;
                }
                else
                {
                    auto init = locatedStatement(Statement.Kind.expression, peek());
                    init.expression = parseExpression();
                    statement.init = init;
                }
            }
            consume(TokenKind.semicolon, "Expected ';' after for initializer");

            if (!check(TokenKind.semicolon))
            {
                statement.condition = parseExpression();
            }
            consume(TokenKind.semicolon, "Expected ';' after for condition");

            if (!check(TokenKind.rightParen))
            {
                statement.incrementStatement = parseForIncrementStatement();
            }
            consume(TokenKind.rightParen, "Expected ')' after for clauses");

            statement.body = [parseStatement()];
            return statement;
        }

        if (match(TokenKind.keywordForeach))
        {
            auto statement = locatedStatement(Statement.Kind.foreach_, previous());
            consume(TokenKind.leftParen, "Expected '(' after foreach");
            statement.iteratorName = consume(TokenKind.identifier, "Expected iterator variable").lexeme;
            if (match(TokenKind.comma))
            {
                statement.iteratorSecondName = consume(TokenKind.identifier,
                    "Expected second iterator variable after ','").lexeme;
            }
            consume(TokenKind.semicolon, "Expected ';' between iterator and iterable");
            statement.iterable = parseExpression();
            consume(TokenKind.rightParen, "Expected ')' after foreach clauses");
            statement.body = [parseStatement()];
            return statement;
        }

        if (match(TokenKind.keywordSwitch))
        {
            auto statement = locatedStatement(Statement.Kind.switch_, previous());
            consume(TokenKind.leftParen, "Expected '(' after switch");
            statement.expression = parseExpression();
            consume(TokenKind.rightParen, "Expected ')' after switch expression");
            consume(TokenKind.leftBrace, "Expected '{' after switch");

            auto cases = appender!(SwitchCase[])();
            while (!check(TokenKind.rightBrace) && !check(TokenKind.eof))
            {
                if (match(TokenKind.keywordCase))
                {
                    auto pattern = parseExpression();
                    consume(TokenKind.colon, "Expected ':' after case value");
                    cases.put(new SwitchCase(false, pattern, parseSwitchCaseBody()));
                    continue;
                }
                if (match(TokenKind.keywordDefault))
                {
                    consume(TokenKind.colon, "Expected ':' after default");
                    cases.put(new SwitchCase(true, null, parseSwitchCaseBody()));
                    continue;
                }
                auto token = peek();
                enforce(false, format("Expected case/default in switch at %s:%s", token.line, token.column));
            }

            consume(TokenKind.rightBrace, "Expected '}' after switch body");
            statement.switchCases = cases.data;
            return statement;
        }

        if (match(TokenKind.keywordFn))
        {
            auto statement = locatedStatement(Statement.Kind.functionDecl, previous());
            statement.isExported = exportPrefix;
            statement.name = consume(TokenKind.identifier, "Expected function name").lexeme;
            parseFunctionSignature(statement.parameters, statement.variadic, statement.body);
            return statement;
        }

        if (exportPrefix)
        {
            auto statement = locatedStatement(Statement.Kind.export_, exportToken);
            statement.name = consume(TokenKind.identifier, "Expected identifier after export").lexeme;
            consume(TokenKind.semicolon, "Expected ';' after export statement");
            return statement;
        }

        auto target = parseExpression();
        auto targets = appender!(Expression[])();
        targets.put(target);
        while (match(TokenKind.comma))
        {
            targets.put(parseExpression());
        }
        if (match(TokenKind.equal))
        {
            auto statement = locatedStatement(Statement.Kind.assign, previous());
            statement.targets = targets.data;
            statement.target = statement.targets[0];
            statement.expressions = parseExpressionList();
            statement.expression = statement.expressions[0];
            consume(TokenKind.semicolon, "Expected ';' after assignment");
            return statement;
        }

        auto statement = locatedStatement(Statement.Kind.expression, Token(TokenKind.eof, "", target.line, target.column));
        enforce(targets.data.length == 1, "Comma-separated expressions require assignment");
        statement.expression = target;
        consume(TokenKind.semicolon, "Expected ';' after expression");
        return statement;
    }

    Statement[] parseSwitchCaseBody()
    {
        auto body = appender!(Statement[])();
        while (!check(TokenKind.keywordCase)
            && !check(TokenKind.keywordDefault)
            && !check(TokenKind.rightBrace)
            && !check(TokenKind.eof))
        {
            body.put(parseStatement());
        }
        return body.data;
    }

    Statement[] parseBlockTail()
    {
        auto statements = appender!(Statement[])();
        while (!check(TokenKind.rightBrace) && !check(TokenKind.eof))
        {
            statements.put(parseStatement());
        }
        consume(TokenKind.rightBrace, "Expected '}' after block");
        return statements.data;
    }

    Expression parseExpression()
    {
        return parseTernary();
    }

    Expression[] parseExpressionList()
    {
        auto expressions = appender!(Expression[])();
        expressions.put(parseExpression());
        while (match(TokenKind.comma))
        {
            expressions.put(parseExpression());
        }
        return expressions.data;
    }

    Statement parseForIncrementStatement()
    {
        auto target = parseExpression();
        if (match(TokenKind.equal))
        {
            auto statement = locatedStatement(Statement.Kind.assign, previous());
            statement.target = target;
            statement.targets = [target];
            statement.expression = parseExpression();
            statement.expressions = [statement.expression];
            return statement;
        }

        auto statement = locatedStatement(Statement.Kind.expression, Token(TokenKind.eof, "", target.line, target.column));
        statement.expression = target;
        return statement;
    }

    string parseTableKey()
    {
        if (match(TokenKind.string_))
        {
            return previous().lexeme;
        }

        if (match(TokenKind.identifier))
        {
            auto key = previous().lexeme;
            while (check(TokenKind.tilde)
                || check(TokenKind.plus)
                || check(TokenKind.minus)
                || check(TokenKind.star)
                || check(TokenKind.slash)
                || check(TokenKind.percent)
                || check(TokenKind.equalEqual)
                || check(TokenKind.bangEqual)
                || check(TokenKind.less)
                || check(TokenKind.lessEqual)
                || check(TokenKind.greater)
                || check(TokenKind.greaterEqual))
            {
                key ~= advance().lexeme;
            }
            return key;
        }

        auto token = peek();
        enforce(false, format("Expected table key at %s:%s", token.line, token.column));
        assert(0);
    }

    Expression parseTernary()
    {
        auto condition = parseLogicalOr();
        if (match(TokenKind.question))
        {
            auto node = new Expression(Expression.Kind.ternary);
            node.line = condition.line;
            node.column = condition.column;
            node.left = condition;
            node.middle = parseExpression();
            consume(TokenKind.colon, "Expected ':' in ternary expression");
            node.right = parseTernary();
            return node;
        }
        return condition;
    }

    Expression parseLogicalOr()
    {
        auto expression = parseLogicalAnd();
        while (match(TokenKind.pipePipe))
        {
            auto node = locatedExpression(Expression.Kind.binary, previous());
            node.operatorSymbol = previous().lexeme;
            node.left = expression;
            node.right = parseLogicalAnd();
            expression = node;
        }
        return expression;
    }

    Expression parseLogicalAnd()
    {
        auto expression = parseBitwiseOr();
        while (match(TokenKind.ampAmp))
        {
            auto node = locatedExpression(Expression.Kind.binary, previous());
            node.operatorSymbol = previous().lexeme;
            node.left = expression;
            node.right = parseBitwiseOr();
            expression = node;
        }
        return expression;
    }

    Expression parseBitwiseOr()
    {
        auto expression = parseBitwiseXor();
        while (match(TokenKind.pipe))
        {
            auto node = locatedExpression(Expression.Kind.binary, previous());
            node.operatorSymbol = previous().lexeme;
            node.left = expression;
            node.right = parseBitwiseXor();
            expression = node;
        }
        return expression;
    }

    Expression parseBitwiseXor()
    {
        auto expression = parseBitwiseAnd();
        while (match(TokenKind.caret))
        {
            auto node = locatedExpression(Expression.Kind.binary, previous());
            node.operatorSymbol = previous().lexeme;
            node.left = expression;
            node.right = parseBitwiseAnd();
            expression = node;
        }
        return expression;
    }

    Expression parseBitwiseAnd()
    {
        auto expression = parseEquality();
        while (match(TokenKind.amp))
        {
            auto node = locatedExpression(Expression.Kind.binary, previous());
            node.operatorSymbol = previous().lexeme;
            node.left = expression;
            node.right = parseEquality();
            expression = node;
        }
        return expression;
    }

    Expression parseEquality()
    {
        auto expression = parseComparison();
        while (match(TokenKind.equalEqual, TokenKind.bangEqual))
        {
            auto node = locatedExpression(Expression.Kind.binary, previous());
            node.operatorSymbol = previous().lexeme;
            node.left = expression;
            node.right = parseComparison();
            expression = node;
        }
        return expression;
    }

    Expression parseComparison()
    {
        auto expression = parseShift();
        while (match(TokenKind.less, TokenKind.lessEqual, TokenKind.greater, TokenKind.greaterEqual))
        {
            auto node = locatedExpression(Expression.Kind.binary, previous());
            node.operatorSymbol = previous().lexeme;
            node.left = expression;
            node.right = parseShift();
            expression = node;
        }
        return expression;
    }

    Expression parseShift()
    {
        auto expression = parseTerm();
        while (match(TokenKind.shiftLeft, TokenKind.shiftRight))
        {
            auto node = locatedExpression(Expression.Kind.binary, previous());
            node.operatorSymbol = previous().lexeme;
            node.left = expression;
            node.right = parseTerm();
            expression = node;
        }
        return expression;
    }

    Expression parseTerm()
    {
        auto expression = parseFactor();
        while (match(TokenKind.plus, TokenKind.minus, TokenKind.tilde))
        {
            auto node = locatedExpression(Expression.Kind.binary, previous());
            node.operatorSymbol = previous().lexeme;
            node.left = expression;
            node.right = parseFactor();
            expression = node;
        }
        return expression;
    }

    Expression parseFactor()
    {
        auto expression = parseUnary();
        while (match(TokenKind.star, TokenKind.slash, TokenKind.percent))
        {
            auto node = locatedExpression(Expression.Kind.binary, previous());
            node.operatorSymbol = previous().lexeme;
            node.left = expression;
            node.right = parseUnary();
            expression = node;
        }
        return expression;
    }

    Expression parseUnary()
    {
        if (match(TokenKind.bang, TokenKind.minus))
        {
            auto node = locatedExpression(Expression.Kind.unary, previous());
            node.operatorSymbol = previous().lexeme;
            node.right = parseUnary();
            return node;
        }
        return parsePostfix();
    }

    Expression parsePostfix()
    {
        auto expression = parsePrimary();
        while (true)
        {
            if (match(TokenKind.leftParen))
            {
                auto call = locatedExpression(Expression.Kind.call, previous());
                call.left = expression;
                auto args = appender!(Expression[])();
                if (!check(TokenKind.rightParen))
                {
                    do
                    {
                        args.put(parseExpression());
                    }
                    while (match(TokenKind.comma));
                }
                consume(TokenKind.rightParen, "Expected ')' after arguments");
                call.arguments = args.data;
                expression = call;
                continue;
            }
            if (match(TokenKind.dot))
            {
                auto get = locatedExpression(Expression.Kind.get, previous());
                get.left = expression;
                get.identifier = consume(TokenKind.identifier, "Expected property name after '.'").lexeme;
                expression = get;
                continue;
            }
            if (match(TokenKind.leftBracket))
            {
                auto index = locatedExpression(Expression.Kind.index, previous());
                index.left = expression;
                index.right = parseExpression();
                if (match(TokenKind.dotDot))
                {
                    index.operatorSymbol = "..";
                    index.middle = index.right;
                    index.right = parseExpression();
                }
                consume(TokenKind.rightBracket, "Expected ']' after index expression");
                expression = index;
                continue;
            }
            break;
        }
        return expression;
    }

    Expression parsePrimary()
    {
        if (match(TokenKind.number))
        {
            auto node = locatedExpression(Expression.Kind.literal, previous());
            auto token = previous();
            node.literalValue = canFind(token.lexeme, ".")
                ? Value.from(token.lexeme.to!double)
                : Value.from(token.lexeme.to!long);
            return node;
        }
        if (match(TokenKind.string_))
        {
            auto node = locatedExpression(Expression.Kind.literal, previous());
            node.literalValue = Value.from(previous().lexeme);
            return node;
        }
        if (match(TokenKind.keywordTrue))
        {
            auto node = locatedExpression(Expression.Kind.literal, previous());
            node.literalValue = Value.from(true);
            return node;
        }
        if (match(TokenKind.keywordFalse))
        {
            auto node = locatedExpression(Expression.Kind.literal, previous());
            node.literalValue = Value.from(false);
            return node;
        }
        if (match(TokenKind.keywordNull))
        {
            auto node = locatedExpression(Expression.Kind.literal, previous());
            node.literalValue = Value.nullValue();
            return node;
        }
        if (match(TokenKind.dollar))
        {
            auto node = locatedExpression(Expression.Kind.unary, previous());
            node.operatorSymbol = previous().lexeme;
            return node;
        }
        if (match(TokenKind.identifier))
        {
            auto node = locatedExpression(Expression.Kind.variable, previous());
            node.identifier = previous().lexeme;
            return node;
        }
        if (match(TokenKind.keywordThis))
        {
            auto node = locatedExpression(Expression.Kind.variable, previous());
            node.identifier = "this";
            return node;
        }
        if (match(TokenKind.leftBracket))
        {
            return parseArrayLiteral(previous());
        }
        if (match(TokenKind.hashLeftBracket))
        {
            return parseArrayLiteral(previous());
        }
        if (match(TokenKind.leftBrace))
        {
            return parseTableLiteral(previous());
        }
        if (match(TokenKind.hashLeftBrace))
        {
            return parseTableLiteral(previous());
        }
        if (match(TokenKind.keywordFn))
        {
            auto node = locatedExpression(Expression.Kind.function_, previous());
            if (check(TokenKind.identifier)
                && (peekAt(1).kind == TokenKind.fatArrow || peekAt(1).kind == TokenKind.colonGreater))
            {
                node.parameters = [consume(TokenKind.identifier, "Expected lambda parameter name").lexeme];
                node.variadic = false;
                auto operatorToken = consumeArrowLike("Expected '=>' or ':>' after lambda parameter");
                auto shorthandResult = parseExpression();
                node.body = operatorToken.kind == TokenKind.fatArrow
                    ? makeImplicitReturnBody(shorthandResult)
                    : makeImplicitSubroutineBody(shorthandResult);
                return node;
            }
            if (check(TokenKind.leftParen) && isArrowLikeFunctionExpressionWithParen())
            {
                parseArrowParameterList(node.parameters, node.variadic);
                auto operatorToken = consumeArrowLike("Expected '=>' or ':>' after lambda parameters");
                auto shorthandResult = parseExpression();
                node.body = operatorToken.kind == TokenKind.fatArrow
                    ? makeImplicitReturnBody(shorthandResult)
                    : makeImplicitSubroutineBody(shorthandResult);
                return node;
            }
            parseFunctionSignature(node.parameters, node.variadic, node.body);
            return node;
        }
        if (match(TokenKind.leftParen))
        {
            auto expression = parseExpression();
            consume(TokenKind.rightParen, "Expected ')' after grouping");
            return expression;
        }

        auto token = peek();
        enforce(false, format("Unexpected token %s at %s:%s", token.kind, token.line, token.column));
        assert(0);
    }

    Expression parseArrayLiteral(Token startToken)
    {
        auto node = locatedExpression(Expression.Kind.array, startToken);
        auto items = appender!(Expression[])();
        if (!check(TokenKind.rightBracket))
        {
            do
            {
                items.put(parseExpression());
            }
            while (match(TokenKind.comma));
        }
        consume(TokenKind.rightBracket, "Expected ']' after array literal");
        node.arguments = items.data;
        return node;
    }

    Expression parseTableLiteral(Token startToken)
    {
        auto node = locatedExpression(Expression.Kind.table, startToken);
        auto entries = appender!(TableEntry[])();
        size_t arrayIndex = 0;
        if (!check(TokenKind.rightBrace))
        {
            do
            {
                if (match(TokenKind.leftBracket))
                {
                    auto keyExpression = parseExpression();
                    consume(TokenKind.rightBracket, "Expected ']' after table key expression");
                    consume(TokenKind.equal, "Expected '=' after table key expression");
                    entries.put(new TableEntry("", keyExpression, parseExpression()));
                    continue;
                }

                if (check(TokenKind.identifier) || check(TokenKind.string_))
                {
                    auto checkpoint = position;
                    auto key = parseTableKey();
                    if (match(TokenKind.equal))
                    {
                        entries.put(new TableEntry(key, null, parseExpression()));
                        continue;
                    }
                    position = checkpoint;
                }

                entries.put(new TableEntry(arrayIndex.to!string, null, parseExpression(), true));
                ++arrayIndex;
            }
            while (match(TokenKind.comma));
        }
        consume(TokenKind.rightBrace, "Expected '}' after table literal");
        node.entries = entries.data;
        return node;
    }

    void parseFunctionSignature(out string[] parameters, out bool variadic, out Statement[] body)
    {
        consume(TokenKind.leftParen, "Expected '(' after function name");
        auto params = appender!(string[])();
        variadic = false;
        if (!check(TokenKind.rightParen))
        {
            do
            {
                auto name = consume(TokenKind.identifier, "Expected parameter name").lexeme;
                if (match(TokenKind.ellipsis))
                {
                    variadic = true;
                    params.put(name);
                    break;
                }
                params.put(name);
            }
            while (match(TokenKind.comma));
        }
        consume(TokenKind.rightParen, "Expected ')' after parameters");
        consume(TokenKind.leftBrace, "Expected '{' before function body");
        body = parseBlockTail();
        parameters = params.data;
    }

    void parseArrowParameterList(out string[] parameters, out bool variadic)
    {
        consume(TokenKind.leftParen, "Expected '(' after function name");
        auto params = appender!(string[])();
        variadic = false;
        if (!check(TokenKind.rightParen))
        {
            do
            {
                auto name = consume(TokenKind.identifier, "Expected parameter name").lexeme;
                if (match(TokenKind.ellipsis))
                {
                    variadic = true;
                    params.put(name);
                    break;
                }
                params.put(name);
            }
            while (match(TokenKind.comma));
        }
        consume(TokenKind.rightParen, "Expected ')' after parameters");
        parameters = params.data;
    }

    Statement[] makeImplicitReturnBody(Expression expression)
    {
        auto returnStatement = new Statement(Statement.Kind.return_);
        returnStatement.line = expression.line;
        returnStatement.column = expression.column;
        returnStatement.expressions = [expression];
        returnStatement.expression = expression;
        return [returnStatement];
    }

    Statement[] makeImplicitSubroutineBody(Expression expression)
    {
        auto expressionStatement = new Statement(Statement.Kind.expression);
        expressionStatement.line = expression.line;
        expressionStatement.column = expression.column;
        expressionStatement.expression = expression;

        auto returnStatement = new Statement(Statement.Kind.return_);
        returnStatement.line = expression.line;
        returnStatement.column = expression.column;
        return [expressionStatement, returnStatement];
    }

    bool isArrowLikeFunctionExpressionWithParen() const
    {
        if (!check(TokenKind.leftParen))
        {
            return false;
        }
        size_t cursor = position + 1;
        if (cursor >= tokens.length)
        {
            return false;
        }
        if (tokens[cursor].kind != TokenKind.rightParen)
        {
            while (cursor < tokens.length)
            {
                if (tokens[cursor].kind != TokenKind.identifier)
                {
                    return false;
                }
                ++cursor;
                if (cursor < tokens.length && tokens[cursor].kind == TokenKind.ellipsis)
                {
                    ++cursor;
                    break;
                }
                if (cursor < tokens.length && tokens[cursor].kind == TokenKind.comma)
                {
                    ++cursor;
                    continue;
                }
                break;
            }
        }
        return cursor + 1 < tokens.length
            && tokens[cursor].kind == TokenKind.rightParen
            && (tokens[cursor + 1].kind == TokenKind.fatArrow
                || tokens[cursor + 1].kind == TokenKind.colonGreater);
    }

    Token consumeArrowLike(string message)
    {
        if (check(TokenKind.fatArrow) || check(TokenKind.colonGreater))
        {
            return advance();
        }
        auto token = peek();
        enforce(false, format("%s at %s:%s", message, token.line, token.column));
        assert(0);
    }

    string parseModuleName()
    {
        if (match(TokenKind.string_))
        {
            return previous().lexeme;
        }

        auto parts = appender!(string[])();
        parts.put(consume(TokenKind.identifier, "Expected module name").lexeme);
        while (match(TokenKind.dot))
        {
            parts.put(consume(TokenKind.identifier, "Expected module segment after '.'").lexeme);
        }
        return parts.data.join(".");
    }

    string lastModuleSegment(string moduleName) const
    {
        auto lastDot = moduleName.lastIndexOf(".");
        if (lastDot == -1)
        {
            return moduleName;
        }
        return moduleName[lastDot + 1 .. $];
    }

    Token peekAt(size_t offset) const
    {
        auto index = position + offset;
        if (index < tokens.length)
        {
            return tokens[index];
        }
        return tokens[$ - 1];
    }

    bool match(TokenKind[] kinds...)
    {
        foreach (kind; kinds)
        {
            if (check(kind))
            {
                advance();
                return true;
            }
        }
        return false;
    }

    bool check(TokenKind kind) const
    {
        return position < tokens.length && tokens[position].kind == kind;
    }

    Token advance()
    {
        if (position < tokens.length)
        {
            ++position;
        }
        return previous();
    }

    Token previous() const
    {
        return tokens[position - 1];
    }

    Token peek() const
    {
        return tokens[position];
    }

    Token consume(TokenKind kind, string message)
    {
        if (check(kind))
        {
            return advance();
        }
        auto token = peek();
        enforce(false, format("%s at %s:%s", message, token.line, token.column));
        assert(0);
    }
}
