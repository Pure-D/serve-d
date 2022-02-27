module workspaced.dub.diagnostics;

import workspaced.api;

import std.algorithm;
import std.string;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

int[2] resolveDubDiagnosticRange(scope const(char)[] code,
	scope const(Token)[] tokens, Module parsed, int position,
	scope const(char)[] diagnostic)
{
	if (diagnostic.startsWith("use `is` instead of `==`",
		"use `!is` instead of `!=`"))
	{
		auto expr = new EqualComparisionFinder(position);
		expr.visit(parsed);
		if (expr.result !is null)
		{
			const left = &expr.result.left.tokens[$ - 1];
			const right = &expr.result.right.tokens[0];
			auto between = left[1 .. right - left];
			const tok = between[0];
			if (tok.type == expr.result.operator)
			{
				auto index = cast(int) tok.index;
				return [index, index + 2];
			}
		}
	}
	return [position, position];
}

/// Finds the equals comparision at the given index.
/// Used to resolve issue locations for diagnostics of type
/// - use `is` instead of `==`
/// - use `!is` instead of `!=`
class EqualComparisionFinder : ASTVisitor
{
	this(size_t index)
	{
		this.index = index;
	}

	override void visit(const(CmpExpression) expr)
	{
		if (expr.equalExpression !is null)
		{
			const start = expr.tokens[0].index;
			const last = expr.tokens[$ - 1];
			const end = last.index + last.text.length;
			if (index >= start && index < end)
			{
				result = cast(EqualExpression) expr.equalExpression;
			}
		}
		super.visit(expr);
	}

	alias visit = ASTVisitor.visit;
	size_t index;
	EqualExpression result;
}

unittest
{
	string code = q{void main() {
	if (foo(a == 4) == null)
	{
	}
}}.replace("\r\n", "\n");

	LexerConfig config;
	RollbackAllocator rba;
	StringCache cache = StringCache(64);
	auto tokens = getTokensForParser(cast(ubyte[]) code, config, &cache);
	auto parsed = parseModule(tokens, "equal_finder.d", &rba);

	auto range = resolveDubDiagnosticRange(code, tokens, parsed, 19,
		"use `is` instead of `==` when comparing with `null`");

	assert(range == [31, 33]);
}
