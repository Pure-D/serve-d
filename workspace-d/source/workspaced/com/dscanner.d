module workspaced.com.dscanner;

version (unittest)
debug = ResolveRange;

import std.algorithm;
import std.array;
import std.conv;
import std.experimental.logger;
import std.file;
import std.json;
import std.meta : AliasSeq;
import std.stdio;
import std.sumtype;
import std.traits;
import std.typecons;

import core.sync.mutex;
import core.thread;

import dscanner.analysis.base;
import dscanner.analysis.config;
import dscanner.analysis.run;
import dscanner.symbol_finder;

import inifiled : INI, readINIFile;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;
import dsymbol.builtin.names;
import dsymbol.modulecache : ModuleCache;

import workspaced.api;
import workspaced.dparseext;
import workspaced.helpers;

static immutable LocalImportCheckKEY = "dscanner.suspicious.local_imports";
static immutable LongLineCheckKEY = "dscanner.style.long_line";

@component("dscanner")
class DscannerComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	/// Asynchronously lints the file passed.
	/// If you provide code then the code will be used and file will be ignored.
	/// See_Also: $(LREF getConfig)
	Future!(DScannerIssue[]) lint(string file = "", string ini = "dscanner.ini",
			scope const(char)[] code = "", bool skipWorkspacedPaths = false,
			const StaticAnalysisConfig defaultConfig = StaticAnalysisConfig.init,
			bool resolveRanges = false)
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				if (code.length && !file.length)
					file = "stdin";
				auto config = getConfig(ini, skipWorkspacedPaths, defaultConfig);
				if (!code.length)
					code = readText(file);
				DScannerIssue[] issues;
				if (!code.length)
				{
					ret.finish(issues);
					return;
				}
				RollbackAllocator r;
				const(Token)[] tokens;
				StringCache cache = StringCache(StringCache.defaultBucketCount);
				const Module m = parseModule(file, cast(ubyte[]) code, &r, cache, tokens, issues);
				if (!m)
					throw new Exception(text("parseModule returned null?! - file: '",
						file, "', code: '", code, "'"));

				// resolve syntax errors (immediately set by parseModule)
				if (resolveRanges)
				{
					foreach_reverse (i, ref issue; issues)
					{
						if (!resolveRange(tokens, issue))
							issues = issues.remove(i);
					}
				}

				MessageSet results;
				ModuleCache moduleCache;
				results = analyze(file, m, config, moduleCache, tokens, true);
				if (results is null)
				{
					ret.finish(issues);
					return;
				}
				foreach (msg; results)
				{
					DScannerIssue issue;
					issue.file = msg.fileName;
					issue.line = cast(int) msg.line;
					issue.column = cast(int) msg.column;
					issue.type = typeForWarning(msg.key);
					issue.description = msg.message;
					issue.key = msg.key;
					if (resolveRanges)
					{
						if (!this.resolveRange(tokens, issue))
							continue;
					}
					issues ~= issue;
				}
				ret.finish(issues);
			}
			catch (Throwable e)
			{
				ret.error(e);
			}
		});
		return ret;
	}

	/// Takes line & column from the D-Scanner issue array and resolves the
	/// start & end locations for the issues by changing the values in-place.
	/// In the JSON RPC this returns the modified array, in workspace-d as a
	/// library this changes the parameter values in place.
	void resolveRanges(scope const(char)[] code, scope ref DScannerIssue[] issues)
	{
		LexerConfig config;
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		if (!tokens.length)
			return;

		foreach_reverse (i, ref issue; issues)
		{
			if (!resolveRange(tokens, issue))
				issues = issues.remove(i);
		}
	}

	/// Adjusts a D-Scanner line:column location to a start & end range, potentially
	/// improving the error message through tokens nearby.
	/// Returns: `false` if this issue should be discarded (handled by other issues)
	private bool resolveRange(scope const(Token)[] tokens, ref DScannerIssue issue)
	out
	{
		debug (ResolveRange) if (issue.range != typeof(issue.range).init)
		{
			assert(issue.range[0].line > 0);
			assert(issue.range[0].column > 0);
			assert(issue.range[1].line > 0);
			assert(issue.range[1].column > 0);
		}
	}
	do
	{
		auto tokenIndex = tokens.tokenIndexAtPosition(issue.line, issue.column);
		if (tokenIndex >= tokens.length)
		{
			if (tokens.length)
				issue.range = makeTokenRange(tokens[$ - 1]);
			else
				issue.range = typeof(issue.range).init;
			return true;
		}

		switch (issue.key)
		{
		case null:
			// syntax errors
			if (!adjustRangeForSyntaxError(tokens, tokenIndex, issue))
				return false;
			improveErrorMessage(issue);
			return true;
		case LocalImportCheckKEY:
			if (adjustRangeForLocalImportsError(tokens, tokenIndex, issue))
				return true;
			goto default;
		case LongLineCheckKEY:
			issue.range = makeTokenRange(tokens[tokenIndex], tokens[min($ - 1, tokens.tokenIndexAtPosition(issue.line, 1000))]);
			return true;
		default:
			issue.range = makeTokenRange(tokens[tokenIndex]);
			return true;
		}
	}

	private void improveErrorMessage(ref DScannerIssue issue)
	{
		// identifier is not literally expected
		issue.description = issue.description.replace("`identifier`", "identifier");

		static immutable expectedIdentifierStart = "Expected identifier instead of `";
		static immutable keywordReplacement = "Expected identifier instead of reserved keyword `";
		if (issue.description.startsWith(expectedIdentifierStart))
		{
			if (issue.description.length > expectedIdentifierStart.length + 1
				&& issue.description[expectedIdentifierStart.length].isIdentifierChar)
			{
				// expected identifier instead of keyword (probably) here because
				// first character of "instead of `..." is an identifier character.
				issue.description = keywordReplacement ~ issue.description[expectedIdentifierStart.length .. $];
			}
		}
	}

	private bool adjustRangeForSyntaxError(scope const(Token)[] tokens, size_t currentToken, ref DScannerIssue issue)
	{
		auto s = issue.description;

		if (s.startsWith("Expected `"))
		{
			s = s["Expected ".length .. $];
			if (s.startsWith("`;`"))
			{
				// span after last word
				size_t issueStartExclusive = currentToken;
				foreach_reverse (i, token; tokens[0 .. currentToken])
				{
					if (token.type == tok!";")
					{
						// this ain't right, expected semicolon issue but
						// semicolon is the first thing before this token
						// happens when syntax before is broken, let's discard!
						// for example in `foo.foreach(a;b)`
						return false;
					}
					issueStartExclusive = i;
					if (token.isLikeIdentifier)
						break;
				}

				size_t issueEnd = issueStartExclusive;
				auto line = tokens[issueEnd].line;

				// span until newline or next word character
				foreach (i, token; tokens[issueStartExclusive + 1 .. $])
				{
					if (token.line != line || token.isLikeIdentifier)
						break;
					issueEnd = issueStartExclusive + 1 + i;
				}

				issue.range = [makeTokenEnd(tokens[issueStartExclusive]), makeTokenEnd(tokens[issueEnd])];
				return true;
			}
			else if (s.startsWith("`identifier` instead of `"))
			{
				auto wanted = s["`identifier` instead of `".length .. $];
				if (wanted.length && wanted[0].isIdentifierChar)
				{
					// wants identifier instead of some keyword (probably)
					// happens e.g. after a . and then nothing written and next line contains a keyword
					// want to remove the "instead of" in case it's not in the same line
					if (currentToken > 0 && tokens[currentToken - 1].line != tokens[currentToken].line)
					{
						issue.description = "Expected identifier";
						issue.range = [makeTokenEnd(tokens[currentToken - 1]), makeTokenStart(tokens[currentToken])];
						return true;
					}
				}
			}

			// span from start of last word
			size_t issueStart = min(max(0, cast(ptrdiff_t)tokens.length - 1), currentToken + 1);
			// if a non-identifier was expected, include word before
			if (issueStart > 0 && s.length > 2 && s[1].isDIdentifierSeparatingChar)
				issueStart--;
			foreach_reverse (i, token; tokens[0 .. issueStart])
			{
				issueStart = i;
				if (token.isLikeIdentifier)
					break;
			}

			// span to end of next word
			size_t searchStart = issueStart;
			if (tokens[searchStart].column + tokens[searchStart].tokenText.length <= issue.column)
				searchStart++;
			size_t issueEnd = min(max(0, cast(ptrdiff_t)tokens.length - 1), searchStart);
			foreach (i, token; tokens[searchStart .. $])
			{
				if (token.isLikeIdentifier)
					break;
				issueEnd = searchStart + i;
			}

			issue.range = makeTokenRange(tokens[issueStart], tokens[issueEnd]);
		}
		else
		{
			if (tokens[currentToken].type == tok!"auto")
			{
				// syntax error on the word "auto"
				// check for foreach (auto key; value)

				if (currentToken >= 2
					&& tokens[currentToken - 1].type == tok!"("
					&& (tokens[currentToken - 2].type == tok!"foreach" || tokens[currentToken - 2].type == tok!"foreach_reverse"))
				{
					// this is foreach (auto
					issue.key = "workspaced.foreach-auto";
					issue.description = "foreach (auto key; value) is not valid D "
						~ "syntax. Use foreach (key; value) instead.";
					// range is used in code_actions to remove auto
					issue.range = makeTokenRange(tokens[currentToken]);
					return true;
				}
			}

			issue.range = makeTokenRange(tokens[currentToken]);
		}
		return true;
	}

	// adjusts error location of
	// import |std.stdio;
	// to
	// ~import std.stdio;~
	private bool adjustRangeForLocalImportsError(scope const(Token)[] tokens, size_t currentToken, ref DScannerIssue issue)
	{
		size_t startIndex = currentToken;
		size_t endIndex = currentToken;

		while (startIndex > 0 && tokens[startIndex].type != tok!"import")
			startIndex--;
		while (endIndex < tokens.length && tokens[endIndex].type != tok!";")
			endIndex++;

		issue.range = makeTokenRange(tokens[startIndex], tokens[endIndex]);
		return true;
	}

	/// Gets the used D-Scanner config, optionally reading from a given
	/// dscanner.ini file.
	/// Params:
	///   ini = an ini to load. Only reading from it if it exists. If this is
	///         relative, this function will try both in getcwd and in the
	///         instance.cwd, if an instance is set.
	///   skipWorkspacedPaths = if true, don't attempt to override the given ini
	///         with workspace-d user configs.
	///   defaultConfig = default D-Scanner configuration to use if no user
	///         config exists (workspace-d specific or ini argument)
	StaticAnalysisConfig getConfig(string ini = "dscanner.ini",
		bool skipWorkspacedPaths = false,
		const StaticAnalysisConfig defaultConfig = StaticAnalysisConfig.init)
	{
		import std.path : buildPath;

		StaticAnalysisConfig config = defaultConfig is StaticAnalysisConfig.init
			? defaultStaticAnalysisConfig()
			: cast()defaultConfig;
		if (!skipWorkspacedPaths && getConfigPath("dscanner.ini", ini))
		{
			static bool didWarn = false;
			if (!didWarn)
			{
				warning("Overriding Dscanner ini with workspace-d dscanner.ini config file");
				didWarn = true;
			}
		}
		string cwd = getcwd;
		if (refInstance !is null)
			cwd = refInstance.cwd;

		if (ini.exists)
		{
			readINIFile(config, ini);
		}
		else
		{
			auto p = buildPath(cwd, ini);
			if (p != ini && p.exists)
				readINIFile(config, p);
		}
		return config;
	}

	private const(Module) parseModule(string file, ubyte[] code, RollbackAllocator* p,
			ref StringCache cache, ref const(Token)[] tokens, ref DScannerIssue[] issues)
	{
		LexerConfig config;
		config.fileName = file;
		config.stringBehavior = StringBehavior.source;
		tokens = getTokensForParser(code, config, &cache);

		void addIssue(string fileName, size_t line, size_t column, string message, bool isError)
		{
			issues ~= DScannerIssue(file, cast(int) line, cast(int) column, isError
					? "error" : "warn", message);
		}

		uint err, warn;
		return dparse.parser.parseModule(tokens, file, p, &addIssue, &err, &warn);
	}

	/// Asynchronously lists all definitions in the specified file.
	///
	/// If you provide code the file wont be manually read.
	///
	/// Set verbose to true if you want to receive more temporary symbols and
	/// things that could be considered clutter as well.
	Future!ModuleDefinition listDefinitions(string file,
		scope const(char)[] code = "", bool verbose = false,
		ExtraMask extraMask = ExtraMask.none)
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				ret.finish(listDefinitionsSync(file, code, verbose, extraMask));
			}
			catch (Throwable e)
			{
				ret.error(e);
			}
		});
		return ret;
	}

	/// ditto
	ModuleDefinition listDefinitionsSync(string file,
		scope const(char)[] code = "", bool verbose = false,
		ExtraMask extraMask = ExtraMask.none)
	{
		if (code.length && !file.length)
			file = "stdin";
		if (!code.length)
			code = readText(file);
		if (!code.length)
			return ModuleDefinition.init;

		LexerConfig config;
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);

		RollbackAllocator r;
		uint errorCount, warningCount;
		ParserConfig pconfig = {
			tokens: tokens,
			fileName: file,
			allocator: &r,
			errorCount: &errorCount,
			warningCount: &warningCount,
		};

		auto m = dparse.parser.parseModule(pconfig);

		bool nullOnError = (extraMask & ExtraMask.nullOnError) != 0;
		if (nullOnError && errorCount > 0)
			return ModuleDefinition.init;

		auto defFinder = new DefinitionFinder();
		defFinder.verbose = verbose;
		defFinder.extraMask = extraMask;
		defFinder.visit(m);

		return ModuleDefinition(
			defFinder.definitions,
			defFinder.hasMixin,
		);
	}

	/// Asynchronously finds all definitions of a symbol in the import paths.
	Future!(FileLocation[]) findSymbol(string symbol)
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				import dscanner.utils : expandArgs;

				string[] paths = expandArgs([""] ~ importPaths);
				foreach_reverse (i, path; paths)
					if (path == "stdin")
						paths = paths.remove(i);
				FileLocation[] files;
				findDeclarationOf((fileName, line, column) {
					FileLocation file;
					file.file = fileName;
					file.line = cast(int) line;
					file.column = cast(int) column;
					files ~= file;
				}, symbol, paths);
				ret.finish(files);
			}
			catch (Throwable e)
			{
				ret.error(e);
			}
		});
		return ret;
	}

	/// Returns: all keys & documentation that can be used in a dscanner.ini
	INIEntry[] listAllIniFields()
	{
		import std.traits : getUDAs;

		INIEntry[] ret;
		foreach (mem; __traits(allMembers, StaticAnalysisConfig))
			static if (is(typeof(__traits(getMember, StaticAnalysisConfig, mem)) == string))
			{
				alias docs = getUDAs!(__traits(getMember, StaticAnalysisConfig, mem), INI);
				ret ~= INIEntry(mem, docs.length ? docs[0].msg : "");
			}
		return ret;
	}
}

/// dscanner.ini setting type
struct INIEntry
{
	///
	string name, documentation;
}

/// Issue type returned by lint
struct DScannerIssue
{
	///
	string file;
	/// one-based line & column (in bytes) of this diagnostic location
	int line, column;
	///
	string type;
	///
	string description;
	///
	string key;
	/// Resolved range for content that can be filled with a call to resolveRanges
	ResolvedLocation[2] range;
}

/// Describes a code location in exact byte offset, line number and column for a
/// given source code this was resolved against.
struct ResolvedLocation
{
	/// byte offset of the character in question - may be 0 if line and column are set
	ulong index;
	/// one-based line
	uint line;
	/// one-based character offset inside the line in bytes
	uint column;
}

ResolvedLocation[2] makeTokenRange(const Token token)
{
	return makeTokenRange(token, token);
}

ResolvedLocation[2] makeTokenRange(const Token start, const Token end)
{
	return [makeTokenStart(start), makeTokenEnd(end)];
}

ResolvedLocation makeTokenStart(const Token token)
{
	ResolvedLocation ret;
	ret.index = cast(uint) token.index;
	ret.line = cast(uint) token.line;
	ret.column = cast(uint) token.column;
	return ret;
}

ResolvedLocation makeTokenEnd(const Token token)
{
	import std.string : lineSplitter;

	ResolvedLocation ret;
	auto text = tokenText(token);
	ret.index = token.index + text.length;
	int numLines;
	size_t lastLength;
	foreach (line; lineSplitter(text))
	{
		numLines++;
		lastLength = line.length;
	}
	if (numLines > 1)
	{
		ret.line = cast(uint)(token.line + numLines - 1);
		ret.column = cast(uint)(lastLength + 1);
	}
	else
	{
		ret.line = cast(uint)(token.line);
		ret.column = cast(uint)(token.column + text.length);
	}
	return ret;
}

/// Returned by find-symbol
struct FileLocation
{
	///
	string file;
	/// 1-based line number and column byte offset
	int line, column;
}

/// Extra things you may want in the definitions list
enum ExtraMask
{
	/// no extra definitions will be included
	none = 0,
	/// return null (empty array) when there is a parsing error
	nullOnError = 1 << 0,
	/// Will include all imports inside the definition list
	imports = 1 << 1,
	/// Will include definitions (except variable declarations) from inside functions and unittests as well
	includeFunctionMembers = 1 << 2,
	/// Include variable declarations inside functions and unittests
	includeVariablesInFunctions = 1 << 3,
}

public import workspaced.index_format : DefinitionElement, ModuleDefinition;

bool isVisibleOutside(DefinitionElement.Visibility v)
{
	return v.match!(
		(typeof(null) _) => true,
		(DefinitionElement.BasicVisibility v) => v != DefinitionElement.BasicVisibility.protected_
			&& v != DefinitionElement.BasicVisibility.private_,
		(DefinitionElement.PackageVisibility v) => false
	);
}

bool isPublicImportVisibility(DefinitionElement.Visibility v)
{
	return v.match!(
		(typeof(null) _) => false,
		(DefinitionElement.BasicVisibility v) => v != DefinitionElement.BasicVisibility.protected_
			&& v != DefinitionElement.BasicVisibility.private_,
		(DefinitionElement.PackageVisibility v) => false // TODO: properly resolve this using the calling module
	);
}

private:

string typeForWarning(string key)
{
	switch (key)
	{
	case "dscanner.bugs.backwards_slices":
	case "dscanner.bugs.if_else_same":
	case "dscanner.bugs.logic_operator_operands":
	case "dscanner.bugs.self_assignment":
	case "dscanner.confusing.argument_parameter_mismatch":
	case "dscanner.confusing.brexp":
	case "dscanner.confusing.builtin_property_names":
	case "dscanner.confusing.constructor_args":
	case "dscanner.confusing.function_attributes":
	case "dscanner.confusing.lambda_returns_lambda":
	case "dscanner.confusing.logical_precedence":
	case "dscanner.confusing.struct_constructor_default_args":
	case "dscanner.deprecated.delete_keyword":
	case "dscanner.deprecated.floating_point_operators":
	case "dscanner.if_statement":
	case "dscanner.performance.enum_array_literal":
	case "dscanner.style.allman":
	case "dscanner.style.alias_syntax":
	case "dscanner.style.doc_missing_params":
	case "dscanner.style.doc_missing_returns":
	case "dscanner.style.doc_non_existing_params":
	case "dscanner.style.explicitly_annotated_unittest":
	case "dscanner.style.has_public_example":
	case "dscanner.style.imports_sortedness":
	case "dscanner.style.long_line":
	case "dscanner.style.number_literals":
	case "dscanner.style.phobos_naming_convention":
	case "dscanner.style.undocumented_declaration":
	case "dscanner.suspicious.auto_ref_assignment":
	case "dscanner.suspicious.catch_em_all":
	case "dscanner.suspicious.comma_expression":
	case "dscanner.suspicious.incomplete_operator_overloading":
	case "dscanner.suspicious.incorrect_infinite_range":
	case "dscanner.suspicious.label_var_same_name":
	case "dscanner.suspicious.length_subtraction":
	case "dscanner.suspicious.local_imports":
	case "dscanner.suspicious.missing_return":
	case "dscanner.suspicious.object_const":
	case "dscanner.suspicious.redundant_attributes":
	case "dscanner.suspicious.redundant_parens":
	case "dscanner.suspicious.static_if_else":
	case "dscanner.suspicious.unmodified":
	case "dscanner.suspicious.unused_label":
	case "dscanner.suspicious.unused_parameter":
	case "dscanner.suspicious.unused_variable":
	case "dscanner.suspicious.useless_assert":
	case "dscanner.unnecessary.duplicate_attribute":
	case "dscanner.useless.final":
	case "dscanner.useless-initializer":
	case "dscanner.vcall_ctor":
		return "warn";
	case "dscanner.syntax":
		return "error";
	default:
		stderr.writeln("Warning: unimplemented DScanner reason, assuming warning: ", key);
		return "warn";
	}
}

final class DefinitionFinder : ASTVisitor
{
	override void visit(const ClassDeclaration dec)
	{
		if (!dec.structBody)
			return;
		definitions ~= makeDefinition(dec.name.text, dec.name.line, 'c', context,
			dec.safeRange);
		auto c = context;
		context = ContextType(["class": dec.name.text], null, c, DefinitionElement.BasicVisibility.default_);
		context.insideAggregate = true;
		dec.accept(this);
		context = c;
	}

	override void visit(const StructDeclaration dec)
	{
		if (!dec.structBody)
			return;
		if (dec.name == tok!"")
		{
			dec.accept(this);
			return;
		}
		definitions ~= makeDefinition(dec.name.text, dec.name.line, 's', context,
			dec.safeRange);
		auto c = context;
		context = ContextType(["struct": dec.name.text], null, c, DefinitionElement.BasicVisibility.default_);
		context.insideAggregate = true;
		dec.accept(this);
		context = c;
	}

	override void visit(const InterfaceDeclaration dec)
	{
		if (!dec.structBody)
			return;
		definitions ~= makeDefinition(dec.name.text, dec.name.line, 'i', context,
			dec.safeRange);
		auto c = context;
		context = ContextType(["interface:": dec.name.text], null, context);
		context.insideAggregate = true;
		dec.accept(this);
		context = c;
	}

	override void visit(const TemplateDeclaration dec)
	{
		auto def = makeDefinition(dec.name.text, dec.name.line, 'T', context,
			dec.safeRange);
		def.attributes["signature"] = paramsToString(dec);
		definitions ~= def;
		auto c = context;
		context = ContextType(["template": dec.name.text], null, context);
		context.insideAggregate = true;
		dec.accept(this);
		context = c;
	}

	override void visit(const FunctionDeclaration dec)
	{
		auto def = makeDefinition(dec.name.text, dec.name.line, 'f', context,
			dec.safeRange);
		def.attributes["signature"] = paramsToString(dec);
		if (dec.returnType !is null)
			def.attributes["return"] = astToString(dec.returnType);
		definitions ~= def;
		dec.accept(this);
	}

	override void visit(const Constructor dec)
	{
		auto def = makeDefinition("this", dec.line, 'f', context,
			dec.safeRange);
		def.attributes["signature"] = paramsToString(dec);
		definitions ~= def;
		dec.accept(this);
	}

	override void visit(const Destructor dec)
	{
		definitions ~= makeDefinition("~this", dec.line, 'f', context,
			dec.safeRange);
		dec.accept(this);
	}

	override void visit(const Postblit dec)
	{
		if (verbose)
			definitions ~= makeDefinition("this(this)", dec.line, 'f', context,
				dec.safeRange);
		dec.accept(this);
	}

	override void visit(const EnumDeclaration dec)
	{
		if (!dec.enumBody)
			return;
		definitions ~= makeDefinition(dec.name.text, dec.name.line, 'g', context,
				dec.safeRange);
		auto c = context;
		context = ContextType(["enum": dec.name.text], null, context);
		context.insideAggregate = true;
		dec.accept(this);
		context = c;
	}

	override void visit(const UnionDeclaration dec)
	{
		if (!dec.structBody)
			return;
		if (dec.name == tok!"")
		{
			dec.accept(this);
			return;
		}
		definitions ~= makeDefinition(dec.name.text, dec.name.line, 'u', context,
				dec.safeRange);
		auto c = context;
		context = ContextType(["union": dec.name.text], null, context);
		context.insideAggregate = true;
		dec.accept(this);
		context = c;
	}

	override void visit(const FunctionBody fn)
	{
		auto c = context;
		context.insideFunction = true;
		fn.accept(this);
		context = c;
	}

	override void visit(const AnonymousEnumMember mem)
	{
		definitions ~= makeDefinition(mem.name.text, mem.name.line, 'e', context,
				mem.safeRange);
		mem.accept(this);
	}

	override void visit(const EnumMember mem)
	{
		definitions ~= makeDefinition(mem.name.text, mem.name.line, 'e', context,
				mem.safeRange);
		mem.accept(this);
	}

	override void visit(const VariableDeclaration dec)
	{
		if (shouldAddVariable)
			foreach (i, d; dec.declarators)
				definitions ~= makeDefinition(d.name.text, d.name.line, 'v', context,
					[
						i == 0
							? cast(int) min(
								dec.type ? dec.type.safeStartLocation : size_t.max,
								dec.safeStartLocation
							)
							: cast(int) d.safeStartLocation,
						i == dec.declarators.length - 1
							? cast(int) dec.safeEndLocation
							: cast(int) d.safeEndLocation
					]);
		dec.accept(this);
	}

	override void visit(const AutoDeclaration dec)
	{
		if (shouldAddVariable)
			foreach (i, d; dec.parts)
				definitions ~= makeDefinition(d.identifier.text, d.identifier.line, 'v', context,
					[
						i == 0
							? cast(int) dec.safeStartLocation
							: cast(int) d.safeStartLocation,
						i == dec.parts.length - 1
							? cast(int) dec.safeEndLocation
							: cast(int) d.safeEndLocation
					]);
		dec.accept(this);
	}

	override void visit(const Invariant dec)
	{
		if (!dec.blockStatement)
		{
			auto c = context;
			context.insideFunction = true;
			dec.accept(this);
			context = c;
			return;
		}

		definitions ~= makeDefinition("invariant", dec.line, 'N', context,
				dec.safeRange);

		if ((extraMask & ExtraMask.includeFunctionMembers) == 0)
		{
			auto c = context;
			context.insideFunction = true;
			dec.accept(this);
			context = c;
			return;
		}

		auto c = context;
		context.insideFunction = true;
		dec.accept(this);
		context = c;
	}

	override void visit(const ModuleDeclaration dec)
	{
		context = ContextType(null, null, context, DefinitionElement.BasicVisibility.default_);
		dec.accept(this);
	}

	override void visit(const Attribute attribute)
	{
		if (attribute.attribute != tok!"")
		{
			switch (attribute.attribute.type)
			{
			case tok!"export":
				context.visibility = DefinitionElement.BasicVisibility.export_;
				break;
			case tok!"public":
				context.visibility = DefinitionElement.BasicVisibility.public_;
				break;
			case tok!"package":
				context.visibility = DefinitionElement.PackageVisibility(
					attribute.identifierChain
						? attribute.identifierChain.identifiers.map!"a.text".join(".")
						: null
				);
				break;
			case tok!"protected":
				context.visibility = DefinitionElement.BasicVisibility.protected_;
				break;
			case tok!"private":
				context.visibility = DefinitionElement.BasicVisibility.private_;
				break;
			default:
			}
		}
		else if (attribute.deprecated_ !is null)
		{
			string reason;
			if (attribute.deprecated_.assignExpression)
				reason = evaluateExpressionString(attribute.deprecated_.assignExpression);
			context.attr["deprecation"] = reason.length ? reason : "";
		}

		attribute.accept(this);
	}

	override void visit(const AtAttribute atAttribute)
	{
		if (atAttribute.argumentList)
		{
			foreach (item; atAttribute.argumentList.items)
			{
				auto str = evaluateExpressionString(item);

				if (str !is null)
					context.privateAttr["utName"] = str;
			}
		}
		atAttribute.accept(this);
	}

	override void visit(const AttributeDeclaration dec)
	{
		accessSt = AccessState.Keep;
		dec.accept(this);
	}

	override void visit(const Declaration dec)
	{
		auto c = context;
		dec.accept(this);

		final switch (accessSt) with (AccessState)
		{
		case Reset:
			context = c;
			break;
		case Keep:
			break;
		}
		accessSt = AccessState.Reset;
	}

	override void visit(const DebugSpecification dec)
	{
		if (!verbose)
			return;

		auto tok = dec.identifierOrInteger;
		auto def = makeDefinition(tok.tokenText, tok.line, 'D', context,
				dec.safeRange);

		definitions ~= def;
		dec.accept(this);
	}

	override void visit(const VersionSpecification dec)
	{
		if (!verbose)
			return;

		auto tok = dec.token;
		auto def = makeDefinition(tok.tokenText, tok.line, 'V', context,
				dec.safeRange);

		definitions ~= def;
		dec.accept(this);
	}

	override void visit(const Unittest dec)
	{
		if (!dec.blockStatement)
			return;

		if (!verbose)
		{
			auto c = context;
			context.insideFunction = true;
			dec.accept(this);
			context = c;
			return;
		}

		string testName = text("__unittest_L", dec.line, "_C", dec.column);
		definitions ~= makeDefinition(testName, dec.line, 'U', context,
				dec.safeRange, "U");

		if ((extraMask & ExtraMask.includeFunctionMembers) == 0)
		{
			auto c = context;
			context.insideFunction = true;
			dec.accept(this);
			context = c;
			return;
		}

		auto c = context;
		context.insideFunction = true;
		dec.accept(this);
		context = c;
	}

	private static immutable CtorTypes = ['C', 'S', 'Q', 'W'];
	private static immutable CtorNames = [
		"static this()", "shared static this()",
		"static ~this()", "shared static ~this()"
	];
	static foreach (i, T; AliasSeq!(StaticConstructor, SharedStaticConstructor,
			StaticDestructor, SharedStaticDestructor))
	{
		override void visit(const T dec)
		{
			if (!verbose)
			{
				dec.accept(this);
				return;
			}

			definitions ~= makeDefinition(CtorNames[i], dec.line, CtorTypes[i], context,
				dec.safeRange);

			dec.accept(this);
		}
	}

	override void visit(const AliasDeclaration dec)
	{
		// Old style alias
		if (dec.declaratorIdentifierList)
			foreach (i; dec.declaratorIdentifierList.identifiers)
				definitions ~= makeDefinition(i.text, i.line, 'a', context,
						i.safeRange);
		dec.accept(this);
	}

	override void visit(const AliasInitializer dec)
	{
		definitions ~= makeDefinition(dec.name.text, dec.name.line, 'a', context,
				dec.safeRange);

		dec.accept(this);
	}

	override void visit(const AliasThisDeclaration dec)
	{
		auto name = dec.identifier;
		definitions ~= makeDefinition(name.text, name.line, 'a', context,
				dec.safeRange);

		dec.accept(this);
	}

	override void visit(const ConditionalStatement conditional)
	{
		if (!conditional.compileCondition)
			return super.visit(conditional);

		if (conditional.trueStatement)
		{
			scope c = context;
			context = makeConditionalContext(conditional.compileCondition, false);
			conditional.trueStatement.accept(this);
			context = c;
		}
		if (conditional.falseStatement)
		{
			scope c = context;
			context = makeConditionalContext(conditional.compileCondition, true);
			conditional.falseStatement.accept(this);
			context = c;
		}
	}

	override void visit(const ConditionalDeclaration conditional)
	{
		if (!conditional.compileCondition)
			return super.visit(conditional);

		if (conditional.trueDeclarations.length)
		{
			scope c = context;
			context = makeConditionalContext(conditional.compileCondition, false);
			foreach (d; conditional.trueDeclarations)
				d.accept(this);
			context = c;
		}
		if (conditional.falseDeclarations.length)
		{
			scope c = context;
			context = makeConditionalContext(conditional.compileCondition, true);
			foreach (d; conditional.falseDeclarations)
				d.accept(this);
			context = c;
		}
	}

	private ContextType makeConditionalContext(const CompileCondition cond, bool invert)
	{
		ContextType ret = context;
		if (cond.versionCondition)
			ret.versions ~= DefinitionElement.VersionCondition(cond.versionCondition.token.text, invert);
		if (cond.debugCondition)
			ret.versions ~= DefinitionElement.VersionCondition(cond.debugCondition.identifierOrInteger.text, invert);
		if (cond.staticIfCondition)
			ret.hasOtherConditional = true;
		return ret;
	}

	override void visit(const ImportDeclaration decl)
	{
		if ((extraMask & ExtraMask.imports) == 0)
			return;

		void process(const SingleImport imp)
		{
			if (!imp.identifierChain)
				return;
			auto ids = imp.identifierChain.identifiers;
			if (ids.length)
			{
				definitions ~= makeDefinition(
					ids.map!"a.text".join("."), ids[0].line, 'I', context, imp.safeRange);
			}
		}

		foreach (imp; decl.singleImports)
			process(imp);
		if (decl.importBindings && decl.importBindings.singleImport)
			process(decl.importBindings.singleImport);
	}

	override void visit(const MixinDeclaration decl)
	{
		hasMixin = true;
		decl.accept(this);
	}

	override void visit(const MixinExpression expr)
	{
		hasMixin = true;
		expr.accept(this);
	}

	bool shouldAddVariable() const @property
	{
		return !context.insideFunction
			|| (extraMask & ExtraMask.includeVariablesInFunctions) != 0;
	}

	alias visit = ASTVisitor.visit;

	ContextType context;
	AccessState accessSt;
	DefinitionElement[] definitions;
	bool hasMixin;
	bool verbose;
	ExtraMask extraMask;
}

DefinitionElement makeDefinition(string name, size_t line, char type,
		ContextType context, int[2] range, string forType = null)
{
	auto ret = DefinitionElement(name, cast(int) line, type, context.attr.dup, range);
	auto access = context.visibility.toLegacyAccess;
	if (access.length)
		ret.attributes["access"] = access;
	ret.visibility = context.visibility;
	ret.versioned = context.versions;
	ret.debugVersioned = context.debugVersions;
	ret.hasOtherConditional = context.hasOtherConditional;
	ret.insideFunction = context.insideFunction;
	ret.insideAggregate = context.insideAggregate;

	if (forType == "U")
	{
		if (auto utName = "utName" in context.privateAttr)
			ret.attributes["name"] = *utName;
	}
	return ret;
}

enum AccessState
{
	Reset, /// when ascending the AST reset back to the previous access.
	Keep /// when ascending the AST keep the new access.
}

struct ContextType
{
	string[string] attr;
	string[string] privateAttr;
	DefinitionElement.Visibility visibility;
	DefinitionElement.VersionCondition[] versions, debugVersions;
	bool hasOtherConditional;
	bool insideFunction;
	bool insideAggregate;

	this(string[string] attr, string[string] privateAttr, ContextType inherit)
	{
		this.attr = attr;
		this.privateAttr = privateAttr;
		this.visibility = inherit.visibility;
		this.versions = inherit.versions;
		this.debugVersions = inherit.debugVersions;
		this.hasOtherConditional = inherit.hasOtherConditional;
		this.insideFunction = inherit.insideFunction;
		this.insideAggregate = inherit.insideAggregate;
	}

	this(T)(string[string] attr, string[string] privateAttr, ContextType inherit, T visibility)
	{
		this(attr, privateAttr, inherit);
		this.visibility = visibility;
	}
}

string toLegacyAccess(DefinitionElement.Visibility v)
{
	return v.match!(
		(typeof(null) _) => null,
		(DefinitionElement.PackageVisibility v) => "protected",
		(other) {
			final switch (other) with (DefinitionElement.BasicVisibility)
			{
			case default_:
			case export_:
			case public_:
				return "public";
			case protected_:
				return "protected";
			case private_:
				return "private";
			}
		}
	);
}

unittest
{
	StaticAnalysisConfig check = StaticAnalysisConfig.init;
	assert(check is StaticAnalysisConfig.init);
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DscannerComponent;
	DscannerComponent dscanner = instance.get!DscannerComponent;

	bool verbose;
	DefinitionElement[] expectedDefinitions;
	runTestDataFileTests("test/data/list_definition",
		() {
			verbose = false;
			expectedDefinitions = null;
		},
		(code, variable, value) {
			switch (variable)
			{
			case "verbose":
				verbose = value.boolean;
				break;
			default:
				assert(false, "Unknown test variable " ~ variable);
			}
		},
		(code, parts, line) {
			assert(parts.length == 6, "malformed definition test line: " ~ line);
			assert(parts[2].length == 1, "malformed type in test line: " ~ line);

			auto expected = DefinitionElement(
				parts[0],
				parts[1].to!int,
				parts[2][0],
				null,
				[parts[4].to!int, parts[5].to!int]
			);
			foreach (k, v; parseJSON(parts[3]).object)
				expected.attributes[k] = v.str;

			expectedDefinitions ~= expected;
		},
		(code) {
			auto defs = dscanner.listDefinitions("stdin", code, verbose).getBlocking()
				.definitions;
			highlightDiff(defs, expectedDefinitions);
		});
}

version (unittest) private void highlightDiff(DefinitionElement[] a, DefinitionElement[] b)
{
	bool equals(DefinitionElement lhs, DefinitionElement rhs)
	{
		return lhs.name == rhs.name
			&& lhs.line == rhs.line
			&& lhs.type == rhs.type
			&& lhs.attributes == rhs.attributes
			&& lhs.range == rhs.range;
	}

	string str(DefinitionElement e)
	{
		return text(e.name, "\t", e.line, "\t", e.type, "\t", e.attributes, "\t", e.range[0], "\t", e.range[1]);
	}

	bool valid = a.length == b.length;
	string ret;
	if (a.length != b.length)
		ret ~= text("length mismatch: ", a.length, " != ", b.length, "\n");
	foreach (i; 0 .. min(a.length, b.length))
	{
		bool same = equals(a[i], b[i]);
		if (!same)
			valid = false;

		if (same)
			ret ~= text("\x1B[0m   ", str(a[i]), "\n");
		else
			ret ~= text("\x1B[33m ! ", str(a[i]), "\n!= ", str(b[i]), "\x1B[0m\n");
	}
	if (a.length < b.length)
	{
		foreach (i; a.length .. b.length)
			ret ~= text("\x1B[31m + ", b[i], "\x1B[0m\n");
	}
	else
	{
		foreach (i; b.length .. a.length)
			ret ~= text("\x1B[31m - ", a[i], "\x1B[0m\n");
	}
	if (!valid)
		assert(false, ret);
}

size_t safeStartLocation(const BaseNode b)
{
	return (b !is null && b.tokens.length > 0) ? b.tokens[0].index : 0;
}

size_t safeEndLocation(const BaseNode b)
{
	return (b !is null && b.tokens.length > 0) ? (b.tokens[$ - 1].index + b.tokens[$ - 1].tokenText.length) : 0;
}

int[2] safeRange(const BaseNode dec)
{
	return [
		cast(int) dec.safeStartLocation,
		cast(int) dec.safeEndLocation
	];
}

int[2] safeRange(const FunctionDeclaration dec)
{
	return [
		cast(int) min(
			dec.safeStartLocation,
			dec.returnType ? dec.returnType.safeStartLocation : size_t.max
		),
		cast(int) dec.safeEndLocation
	];
}

int[2] safeRange(const Token ast)
{
	return [
		cast(int) ast.index,
		cast(int)(ast.index + ast.tokenText.length)
	];
}
