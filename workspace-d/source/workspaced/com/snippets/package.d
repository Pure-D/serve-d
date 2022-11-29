module workspaced.com.snippets;

import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import workspaced.api;
import workspaced.com.dfmt : DfmtComponent;
import workspaced.com.snippets.generator;
import workspaced.dparseext;

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.json;
import std.string;
import std.typecons;

public import workspaced.com.snippets.plain;
public import workspaced.com.snippets.smart;
public import workspaced.com.snippets.dependencies;
public import workspaced.com.snippets.control_flow;

// ugly, but works for now
import mir.algebraic_alias.json : JsonValue = JsonAlgebraic;

/// Component for auto completing snippets with context information and formatting these snippets with dfmt.
@component("snippets")
class SnippetsComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	static PlainSnippetProvider plainSnippets;
	static SmartSnippetProvider smartSnippets;
	static DependencyBasedSnippetProvider dependencySnippets;
	static ControlFlowSnippetProvider controlFlowSnippets;

	protected SnippetProvider[] providers;

	protected void load()
	{
		if (!plainSnippets)
			plainSnippets = new PlainSnippetProvider();
		if (!smartSnippets)
			smartSnippets = new SmartSnippetProvider();
		if (!dependencySnippets)
			dependencySnippets = new DependencyBasedSnippetProvider();
		if (!controlFlowSnippets)
			controlFlowSnippets = new ControlFlowSnippetProvider();

		config.stringBehavior = StringBehavior.source;
		providers.reserve(16);
		providers ~= plainSnippets;
		providers ~= smartSnippets;
		providers ~= dependencySnippets;
		providers ~= controlFlowSnippets;
	}

	/**
	 * Params:
	 *   file = Filename to resolve dependencies relatively from.
	 *   code = Code to complete snippet in.
	 *   position = Byte offset of where to find scope in.
	 *
	 * Returns: a `SnippetInfo` object for all snippet information.
	 *
	 * `.loopScope` is set if a loop can be inserted at this position, Optionally
	 * with information about close ranges. Contains `SnippetLoopScope.init` if
	 * this is not a location where a loop can be inserted.
	 */
	SnippetInfo determineSnippetInfo(scope const(char)[] file, scope const(char)[] code, int position)
	{
		// each variable is 1
		// maybe more expensive lookups with DCD in the future
		enum LoopVariableAnalyzeMaxCost = 90;

		scope tokens = getTokensForParser(cast(const(ubyte)[]) code, config, &workspaced.stringCache);
		auto loc = tokens.tokenIndexAtByteIndex(position);

		// first check if at end of identifier, move current location to that
		// identifier.
		if (loc > 0
			&& loc < tokens.length
			&& tokens[loc - 1].isLikeIdentifier
			&& tokens[loc - 1].index <= position
			&& tokens[loc - 1].index + tokens[loc - 1].textLength >= position)
			loc--;
		// also determine info from before start of identifier (so you can start
		// typing something and it still finds a snippet scope)
		// > double decrement when at end of identifier, start of other token!
		if (loc > 0
			&& loc < tokens.length
			&& tokens[loc].isLikeIdentifier
			&& tokens[loc].index <= position
			&& tokens[loc].index + tokens[loc].textLength >= position)
			loc--;

		// nudge in next token if position is after this token
		if (loc < tokens.length && tokens[loc].isLikeIdentifier
			&& position > tokens[loc].index + tokens[loc].textLength)
		{
			// cursor must not be glued to the end of identifiers
			loc++;
		}
		else if (loc < tokens.length && !tokens[loc].isLikeIdentifier
			&& position >= tokens[loc].index + tokens[loc].textLength)
		{
			// but next token if end of non-identifiers (eg `""`, `;`, `.`, `(`)
			loc++;
		}

		int contextIndex;
		int checkLocation = position;
		if (loc >= 0 && loc < tokens.length)
		{
			contextIndex = cast(int) tokens[loc].index;
			if (tokens[loc].index < position)
				checkLocation = contextIndex;
		}

		if (loc == 0 || loc == tokens.length)
			return SnippetInfo(contextIndex, [SnippetLevel.global]);

		auto leading = tokens[0 .. loc];

		if (leading.length)
		{
			auto last = leading[$ - 1];
			switch (last.type)
			{
			case tok!".":
			case tok!")":
			case tok!"characterLiteral":
			case tok!"dstringLiteral":
			case tok!"wstringLiteral":
			case tok!"stringLiteral":
				// no snippets immediately after these tokens (needs some other
				// token inbetween)
				return SnippetInfo(contextIndex, [SnippetLevel.other]);
			case tok!"(":
				// current token is something like `)`, check for previous
				// tokens like `__traits` `(`
				if (leading.length >= 2)
				{
					switch (leading[$ - 2].type)
					{
					case tok!"__traits":
					case tok!"version":
					case tok!"debug":
						return SnippetInfo(contextIndex, [SnippetLevel.other]);
					default: break;
					}
				}
				break;
			case tok!"__traits":
			case tok!"version":
			case tok!"debug":
				return SnippetInfo(contextIndex, [SnippetLevel.other]);
			case tok!"typeof":
			case tok!"if":
			case tok!"while":
			case tok!"for":
			case tok!"foreach":
			case tok!"foreach_reverse":
			case tok!"switch":
			case tok!"with":
			case tok!"catch":
				// immediately after these tokens, missing opening parentheses
				if (tokens[loc].type != tok!"(")
					return SnippetInfo(contextIndex, [SnippetLevel.other]);
				break;
			default:
				break;
			}
		}

		auto current = tokens[loc];
		switch (current.type)
		{
		case tok!"comment":
			size_t len = max(0, cast(ptrdiff_t)position
				- cast(ptrdiff_t)current.index);
			// TODO: currently never called because we would either need to
			// use the DLexer struct as parser immediately or wait until
			// libdparse >=0.15.0 which contains trivia, where this switch
			// needs to be modified to check the exact trivia token instead
			// of the associated token with it.
			if (current.text[0 .. len].startsWith("///", "/++", "/**"))
				return SnippetInfo(contextIndex, [SnippetLevel.docComment]);
			else if (len >= 2)
				return SnippetInfo(contextIndex, [SnippetLevel.comment]);
			else
				break;
		case tok!"characterLiteral":
		case tok!"dstringLiteral":
		case tok!"wstringLiteral":
		case tok!"stringLiteral":
			if (position <= current.index)
				break;

			auto textSoFar = current.text[1 .. position - current.index];
			// no string complete if we are immediately after escape or
			// quote character
			// TODO: properly check if this is an unescaped escape
			if (textSoFar.endsWith('\\', current.text[0]))
				return SnippetInfo(contextIndex, [SnippetLevel.strings, SnippetLevel.other]);
			else
				return SnippetInfo(contextIndex, [SnippetLevel.strings]);
		default:
			break;
		}

		foreach_reverse (t; leading)
		{
			if (t.type == tok!";")
				break;

			// test for tokens semicolon closed statements where we should abort to avoid incomplete syntax
			if (t.type.among!(tok!"import", tok!"module"))
			{
				return SnippetInfo(contextIndex, [SnippetLevel.global, SnippetLevel.other]);
			}
			else if (t.type.among!(tok!"=", tok!"+", tok!"-", tok!"*", tok!"/",
					tok!"%", tok!"^^", tok!"&", tok!"|", tok!"^", tok!"<<",
					tok!">>", tok!">>>", tok!"~", tok!"in"))
			{
				return SnippetInfo(contextIndex, [SnippetLevel.global, SnippetLevel.value]);
			}
		}

		RollbackAllocator rba;
		scope parsed = parseModule(tokens, cast(string) file, &rba);

		//trace("determineSnippetInfo at ", contextIndex);

		scope gen = new SnippetInfoGenerator(checkLocation);
		gen.value.contextTokenIndex = contextIndex;
		gen.variableStack.reserve(64);
		gen.visit(parsed);

		gen.value.loopScope.supported = gen.value.level == SnippetLevel.method;
		if (gen.value.loopScope.supported)
		{
			int cost = 0;
			foreach_reverse (v; gen.variableStack)
			{
				if (fillLoopScopeInfo(gen.value.loopScope, v))
					break;
				if (++cost > LoopVariableAnalyzeMaxCost)
					break;
			}
		}

		if (gen.lastStatement)
		{
			import dparse.ast;

			LastStatementInfo info;
			auto nodeType = gen.lastStatement.findDeepestNonBlockNode;
			if (gen.lastStatement.tokens.length)
				info.location = cast(int) nodeType.tokens[0].index;
			info.type = typeid(nodeType).name;
			auto lastDot = info.type.lastIndexOf('.');
			if (lastDot != -1)
				info.type = info.type[lastDot + 1 .. $];
			if (auto ifStmt = cast(IfStatement)nodeType)
			{
				auto elseStmt = getIfElse(ifStmt);
				if (cast(IfStatement)elseStmt)
					info.ifHasElse = false;
				else
					info.ifHasElse = elseStmt !is null;
			}
			else if (auto ifStmt = cast(ConditionalDeclaration)nodeType)
				info.ifHasElse = ifStmt.hasElse;
			// if (auto ifStmt = cast(ConditionalStatement)nodeType)
			// 	info.ifHasElse = !!getIfElse(ifStmt);

			gen.value.lastStatement = info;
		}

		return gen.value;
	}

	Future!SnippetList getSnippets(scope const(char)[] file, scope const(char)[] code, int position)
	{
		mixin(gthreadsAsyncProxy!`getSnippetsBlocking(file, code, position)`);
	}

	SnippetList getSnippetsBlocking(scope const(char)[] file, scope const(char)[] code, int position)
	{
		auto futures = collectSnippets(file, code, position);

		auto ret = appender!(Snippet[]);
		foreach (fut; futures[1])
			ret.put(fut.getBlocking());
		return SnippetList(futures[0], ret.data);
	}

	SnippetList getSnippetsYield(scope const(char)[] file, scope const(char)[] code, int position)
	{
		auto futures = collectSnippets(file, code, position);

		auto ret = appender!(Snippet[]);
		foreach (fut; futures[1])
			ret.put(fut.getYield());
		return SnippetList(futures[0], ret.data);
	}

	Future!Snippet resolveSnippet(scope const(char)[] file, scope const(char)[] code,
			int position, Snippet snippet)
	{
		foreach (provider; providers)
		{
			if (typeid(provider).name == snippet.providerId)
			{
				const info = determineSnippetInfo(file, code, position);
				return provider.resolveSnippet(instance, file, code, position, info, snippet);
			}
		}

		return typeof(return).fromResult(snippet);
	}

	Future!string format(scope const(char)[] snippet, string[] arguments = [],
			SnippetLevel level = SnippetLevel.global)
	{
		mixin(gthreadsAsyncProxy!`formatSync(snippet, arguments, level)`);
	}

	/// Will format the code passed in synchronously using dfmt. Might take a short moment on larger documents.
	/// Returns: the formatted code as string or unchanged if dfmt is not active
	string formatSync(scope const(char)[] snippet, string[] arguments = [],
			SnippetLevel level = SnippetLevel.global)
	{
		if (!has!DfmtComponent)
			return snippet.idup;

		auto dfmt = get!DfmtComponent;

		auto tmp = appender!string;

		final switch (level)
		{
		case SnippetLevel.global:
		case SnippetLevel.other:
		case SnippetLevel.comment:
		case SnippetLevel.docComment:
		case SnippetLevel.strings:
		case SnippetLevel.mixinTemplate:
		case SnippetLevel.newMethod:
		case SnippetLevel.loop:
		case SnippetLevel.switch_:
			break;
		case SnippetLevel.type:
			tmp.put("struct FORMAT_HELPER {\n");
			break;
		case SnippetLevel.method:
			tmp.put("void FORMAT_HELPER() {\n");
			break;
		case SnippetLevel.value:
			tmp.put("int FORMAT_HELPER() = ");
			break;
		}

		scope const(char)[][string] tokens;

		ptrdiff_t dollar, last;
		while (true)
		{
			dollar = snippet.indexOfAny(`$\`, last);
			if (dollar == -1)
			{
				tmp ~= snippet[last .. $];
				break;
			}

			tmp ~= snippet[last .. dollar];
			last = dollar + 1;
			if (last >= snippet.length)
				break;
			if (snippet[dollar] == '\\')
			{
				tmp ~= snippet[dollar + 1];
				last = dollar + 2;
			}
			else
			{
				string key = "__WspD_Snp_" ~ dollar.to!string ~ "_";
				const(char)[] str;

				bool startOfBlock = snippet[0 .. dollar].stripRight.endsWith("{");
				bool endOfBlock;

				bool makeWrappingIfMayBeDelegate()
				{
					endOfBlock = snippet[last .. $].stripLeft.startsWith("}");
					if (startOfBlock && endOfBlock)
					{
						// make extra long to make dfmt definitely wrap this (in case this is a delegate, otherwise this doesn't hurt either)
						key.reserve(key.length + 200);
						foreach (i; 0 .. 200)
							key ~= "_";
						return true;
					}
					else
						return false;
				}

				if (snippet[dollar + 1] == '{')
				{
					ptrdiff_t i = dollar + 2;
					int depth = 1;
					while (true)
					{
						auto next = snippet.indexOfAny(`\{}`, i);
						if (next == -1)
						{
							i = snippet.length;
							break;
						}

						if (snippet[next] == '\\')
							i = next + 2;
						else
						{
							if (snippet[next] == '{')
								depth++;
							else if (snippet[next] == '}')
								depth--;
							else
								assert(false);

							i = next + 1;
						}

						if (depth == 0)
							break;
					}
					str = snippet[dollar .. i];
					last = i;

					const wrapped = makeWrappingIfMayBeDelegate();

					const placeholderMightBeIdentifier = str.length > 5
						|| snippet[last .. $].stripLeft.startsWith(";", ".", "{", "(", "[");

					if (wrapped || placeholderMightBeIdentifier)
					{
						// let's insert some token in here instead of a comment because there is probably some default content
						// if there is a semicolon at the end we probably need to insert a semicolon here too
						// if this is a comment placeholder let's insert a semicolon to make dfmt wrap
						if (str[0 .. $ - 1].endsWith(';') || str[0 .. $ - 1].canFind("//"))
							key ~= ';';
					}
					else if (level != SnippetLevel.value)
					{
						// empty default, put in comment
						key = "/+++" ~ key ~ "+++/";
					}
				}
				else
				{
					size_t end = dollar + 1;

					if (snippet[dollar + 1].isDigit)
					{
						while (end < snippet.length && snippet[end].isDigit)
							end++;
					}
					else
					{
						while (end < snippet.length && (snippet[end].isAlphaNum || snippet[end] == '_'))
							end++;
					}

					str = snippet[dollar .. end];
					last = end;

					makeWrappingIfMayBeDelegate();

					const placeholderMightBeIdentifier = snippet[last .. $].stripLeft.startsWith(";",
							".", "{", "(", "[");

					if (placeholderMightBeIdentifier)
					{
						// keep value thing as simple identifier as we don't have any placeholder text
					}
					else if (level != SnippetLevel.value)
					{
						// primitive placeholder as comment
						key = "/+++" ~ key ~ "+++/";
					}
				}

				tokens[key] = str;
				tmp ~= key;
			}
		}

		final switch (level)
		{
		case SnippetLevel.global:
		case SnippetLevel.other:
		case SnippetLevel.comment:
		case SnippetLevel.docComment:
		case SnippetLevel.strings:
		case SnippetLevel.mixinTemplate:
		case SnippetLevel.newMethod:
		case SnippetLevel.loop:
		case SnippetLevel.switch_:
			break;
		case SnippetLevel.type:
		case SnippetLevel.method:
			tmp.put("}");
			break;
		case SnippetLevel.value:
			tmp.put(";");
			break;
		}

		auto res = dfmt.formatSync(tmp.data, arguments);

		string chompStr;
		char del;
		final switch (level)
		{
		case SnippetLevel.global:
		case SnippetLevel.other:
		case SnippetLevel.comment:
		case SnippetLevel.docComment:
		case SnippetLevel.strings:
		case SnippetLevel.mixinTemplate:
		case SnippetLevel.newMethod:
		case SnippetLevel.loop:
		case SnippetLevel.switch_:
			break;
		case SnippetLevel.type:
		case SnippetLevel.method:
			chompStr = "}";
			del = '{';
			break;
		case SnippetLevel.value:
			chompStr = ";";
			del = '=';
			break;
		}

		if (chompStr.length)
			res = res.stripRight.chomp(chompStr);

		if (del != char.init)
		{
			auto start = res.indexOf(del);
			if (start != -1)
			{
				res = res[start + 1 .. $];

				while (true)
				{
					// delete empty lines before first line
					auto nl = res.indexOf('\n');
					if (nl != -1 && res[0 .. nl].all!isWhite)
						res = res[nl + 1 .. $];
					else
						break;
				}

				auto indent = res[0 .. res.length - res.stripLeft.length];
				if (indent.length)
				{
					// remove indentation of whole block
					assert(indent.all!isWhite);
					res = res.splitLines.map!(a => a.startsWith(indent)
							? a[indent.length .. $] : a.stripRight).join("\n");
				}
			}
		}

		foreach (key, value; tokens)
		{
			// TODO: replacing using aho-corasick would be far more efficient but there is nothing like that in phobos
			res = res.replace(key, value);
		}

		if (res.endsWith("\r\n") && !snippet.endsWith('\n'))
			res.length -= 2;
		else if (res.endsWith('\n') && !snippet.endsWith('\n'))
			res.length--;

		if (res.endsWith(";\n\n$0"))
			res = res[0 .. $ - "\n$0".length] ~ "$0";
		else if (res.endsWith(";\r\n\r\n$0"))
			res = res[0 .. $ - "\r\n$0".length] ~ "$0";

		return res;
	}

	/// Adds snippets which complete conditionally based on dub dependencies being present.
	/// This function affects the global configuration of all instances.
	/// Params:
	///   requiredDependencies = The dependencies which must be present in order for this snippet to show up.
	///   snippet = The snippet to suggest when the required dependencies are matched.
	void addDependencySnippet(string[] requiredDependencies, PlainSnippet snippet)
	{
		// maybe application global change isn't such a good idea? Current config system seems too inefficient for this.
		dependencySnippets.addSnippet(requiredDependencies, snippet);
	}

private:
	Tuple!(SnippetInfo, Future!(Snippet[])[]) collectSnippets(scope const(char)[] file,
			scope const(char)[] code, int position)
	{
		const inst = instance;
		auto info = determineSnippetInfo(file, code, position);
		auto futures = appender!(Future!(Snippet[])[]);
		foreach (provider; providers)
			futures.put(provider.provideSnippets(inst, file, code, position, info));
		return tuple(info, futures.data);
	}

	LexerConfig config;
}

///
enum SnippetLevel
{
	/// Outside of functions or types, possibly inside templates
	global,
	/// Inside interfaces, classes, structs or unions
	type,
	/// Inside method body
	method,
	/// inside a variable value, argument call, default value or similar
	value,
	/// Other scope types (for example outside of braces but after a function definition or some other invalid syntax place)
	other,
	/// Inside a string literal.
	strings,
	/// Inside a normal comment
	comment,
	/// Inside a documentation comment
	docComment,
	/// Inside explicitly declared mixin templates
	mixinTemplate,

	/// Inserted at the start of any method, meaning the scope has cleared or at least is logically separated.
	newMethod,
	/// a breakable loop (while, for, foreach, etc.)
	/// This type is usually not the trailing type and will repeat method afterwards.
	loop,
	/// a `switch` statement
	/// This type is usually not the trailing type and will repeat method afterwards.
	switch_,
}

///
struct SnippetLoopScope
{
	/// true if an loop expression can be inserted at this point
	bool supported;
	/// true if we know we are iterating over a string (possibly needing unicode decoding) or false otherwise
	bool stringIterator;
	/// Explicit type to use when iterating or null if none is known
	string type;
	/// Best variable to iterate over or null if none was found
	string iterator;
	/// Number of keys to iterate over
	int numItems = 1;
}

///
struct SnippetInfo
{
	/// Index in code which token was used to determine this snippet info.
	int contextTokenIndex;
	/// Levels this snippet location has gone through, latest one being the last
	SnippetLevel[] stack = [SnippetLevel.global];
	/// Information about snippets using loop context
	SnippetLoopScope loopScope;
	/// Information about the last parsable statement before the cursor. May be
	/// `LastStatementInfo.init` at start of function or block.
	LastStatementInfo lastStatement;

	/// Current snippet scope level of the location
	SnippetLevel level() const @property
	{
		return stack.length ? stack[$ - 1] : SnippetLevel.other;
	}

	/// Checks in reverse if the given snippet level is in the stack, up until
	/// the last newMethod level.
	SnippetLevel findInLocalScope(SnippetLevel[] levels...) const
	{
		foreach_reverse (s; stack)
		{
			if (levels.canFind(s))
				return s;
			if (s == SnippetLevel.newMethod)
				break;
		}
		return SnippetLevel.init;
	}
}

struct LastStatementInfo
{
	/// The libdparse class name (typeid) of the last parsable statement before
	/// the cursor, stripped of module name.
	string type;
	/// If type is set, this is the start location in bytes where
	/// the first token was.
	int location;
	/// True if the type is (`IfStatement`, `ConditionalDeclaration` or
	/// `ConditionalStatement`) and has a final `else` block defined.
	bool ifHasElse;
}

/// A list of snippets resolved at a given position.
struct SnippetList
{
	/// The info where this snippet is completing at.
	SnippetInfo info;
	/// The list of snippets that got returned.
	Snippet[] snippets;
}

///
interface SnippetProvider
{
	Future!(Snippet[]) provideSnippets(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position, const SnippetInfo info);

	Future!Snippet resolveSnippet(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position,
			const SnippetInfo info, Snippet snippet);
}

/// Snippet to insert
struct Snippet
{
	/// Internal ID for resolving this snippet
	string id, providerId;
	/// User-defined data for helping resolving this snippet
	JsonValue data;
	/// Label for this snippet
	string title;
	/// Shortcut to type for this snippet
	string shortcut;
	/// Markdown documentation for this snippet
	string documentation;
	/// Plain text to insert assuming global level indentation.
	string plain;
	/// Text with interactive snippet locations to insert assuming global indentation.
	string snippet;
	/// true if this snippet can be used as-is
	bool resolved;
	/// true if this snippet shouldn't be formatted.
	bool unformatted;
	/// List of imports that should be imported when using this snippet.
	string[] imports;
}
