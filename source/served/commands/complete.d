module served.commands.complete;

import served.commands.format : formatCode, formatSnippet;
import served.extension;
import served.types;
import served.utils.ddoc;
import served.utils.fibermanager;

import workspaced.api;
import workspaced.com.dfmt : DfmtComponent;
import workspaced.com.dcd;
import workspaced.com.snippets;
import workspaced.coms;

import std.algorithm : among, any, canFind, chunkBy, endsWith, filter, map, min,
	reverse, sort, startsWith, uniq;
import std.array : appender, array;
import std.conv : text, to;
import std.experimental.logger;
import std.json : JSONType, JSONValue;
import std.regex : ctRegex, matchFirst;
import std.string : indexOf, join, lastIndexOf, lineSplitter, strip,
	stripLeft, stripRight, toLower;
import std.utf : decodeFront;

import painlessjson : fromJSON, toJSON;

import fs = std.file;
import io = std.stdio;

CompletionItemKind convertFromDCDType(string type)
{
	switch (type)
	{
	case "c": // class name
		return CompletionItemKind.class_;
	case "i": // interface name
		return CompletionItemKind.interface_;
	case "s": // struct name
	case "u": // union name
		return CompletionItemKind.struct_;
	case "a": // array
	case "A": // associative array
	case "v": // variable name
		return CompletionItemKind.variable;
	case "m": // member variable
		return CompletionItemKind.field;
	case "e": // enum member
		return CompletionItemKind.enumMember;
	case "k": // keyword
		return CompletionItemKind.keyword;
	case "f": // function
		return CompletionItemKind.function_;
	case "g": // enum name
		return CompletionItemKind.enum_;
	case "P": // package name
	case "M": // module name
		return CompletionItemKind.module_;
	case "l": // alias name
		return CompletionItemKind.reference;
	case "t": // template name
	case "T": // mixin template name
		return CompletionItemKind.property;
	case "h": // template type parameter
	case "p": // template variadic parameter
		return CompletionItemKind.typeParameter;
	default:
		return CompletionItemKind.text;
	}
}

SymbolKind convertFromDCDSearchType(string type)
{
	switch (type)
	{
	case "c":
		return SymbolKind.class_;
	case "i":
		return SymbolKind.interface_;
	case "s":
	case "u":
		return SymbolKind.package_;
	case "a":
	case "A":
	case "v":
		return SymbolKind.variable;
	case "m":
	case "e":
		return SymbolKind.field;
	case "f":
	case "l":
		return SymbolKind.function_;
	case "g":
		return SymbolKind.enum_;
	case "P":
	case "M":
		return SymbolKind.namespace;
	case "t":
	case "T":
		return SymbolKind.property;
	case "k":
	default:
		return cast(SymbolKind) 0;
	}
}

SymbolKind convertFromDscannerType(string type)
{
	switch (type)
	{
	case "g":
		return SymbolKind.enum_;
	case "e":
		return SymbolKind.field;
	case "v":
		return SymbolKind.variable;
	case "i":
		return SymbolKind.interface_;
	case "c":
		return SymbolKind.class_;
	case "s":
		return SymbolKind.class_;
	case "f":
		return SymbolKind.function_;
	case "u":
		return SymbolKind.class_;
	case "T":
		return SymbolKind.property;
	case "a":
		return SymbolKind.field;
	default:
		return cast(SymbolKind) 0;
	}
}

C[] substr(C, T)(C[] s, T start, T end)
{
	if (!s.length)
		return s;
	if (start < 0)
		start = 0;
	if (start >= s.length)
		start = s.length - 1;
	if (end > s.length)
		end = s.length;
	if (end < start)
		return s[start .. start];
	return s[start .. end];
}

/// Extracts all function parameters for a given declaration string.
/// Params:
///   sig = the function signature such as `string[] example(string sig, bool exact = false)`
///   exact = set to true to make the returned values include the closing paren at the end (if exists)
const(char)[][] extractFunctionParameters(scope const(char)[] sig, bool exact = false)
{
	if (!sig.length)
		return [];
	auto params = appender!(const(char)[][]);
	ptrdiff_t i = sig.length - 1;

	if (sig[i] == ')' && !exact)
		i--;

	ptrdiff_t paramEnd = i + 1;

	void skipStr()
	{
		i--;
		if (sig[i + 1] == '\'')
			for (; i >= 0; i--)
				if (sig[i] == '\'')
					return;
		bool escapeNext = false;
		while (i >= 0)
		{
			if (sig[i] == '\\')
				escapeNext = false;
			if (escapeNext)
				break;
			if (sig[i] == '"')
				escapeNext = true;
			i--;
		}
	}

	void skip(char open, char close)
	{
		i--;
		int depth = 1;
		while (i >= 0 && depth > 0)
		{
			if (sig[i] == '"' || sig[i] == '\'')
				skipStr();
			else
			{
				if (sig[i] == close)
					depth++;
				else if (sig[i] == open)
					depth--;
				i--;
			}
		}
	}

	while (i >= 0)
	{
		switch (sig[i])
		{
		case ',':
			params.put(sig.substr(i + 1, paramEnd).strip);
			paramEnd = i;
			i--;
			break;
		case ';':
		case '(':
			auto param = sig.substr(i + 1, paramEnd).strip;
			if (param.length)
				params.put(param);
			auto ret = params.data;
			reverse(ret);
			return ret;
		case ')':
			skip('(', ')');
			break;
		case '}':
			skip('{', '}');
			break;
		case ']':
			skip('[', ']');
			break;
		case '"':
		case '\'':
			skipStr();
			break;
		default:
			i--;
			break;
		}
	}
	auto ret = params.data;
	reverse(ret);
	return ret;
}

unittest
{
	void assertEqual(A, B)(A a, B b)
	{
		import std.conv : to;

		assert(a == b, a.to!string ~ " is not equal to " ~ b.to!string);
	}

	assertEqual(extractFunctionParameters("void foo()"), cast(string[])[]);
	assertEqual(extractFunctionParameters(`auto bar(int foo, Button, my.Callback cb)`),
			["int foo", "Button", "my.Callback cb"]);
	assertEqual(extractFunctionParameters(`SomeType!(int, "int_") foo(T, Args...)(T a, T b, string[string] map, Other!"(" stuff1, SomeType!(double, ")double") myType, Other!"(" stuff, Other!")")`),
			[
				"T a", "T b", "string[string] map", `Other!"(" stuff1`,
				`SomeType!(double, ")double") myType`, `Other!"(" stuff`, `Other!")"`
			]);
	assertEqual(extractFunctionParameters(`SomeType!(int,"int_")foo(T,Args...)(T a,T b,string[string] map,Other!"(" stuff1,SomeType!(double,")double")myType,Other!"(" stuff,Other!")")`),
			[
				"T a", "T b", "string[string] map", `Other!"(" stuff1`,
				`SomeType!(double,")double")myType`, `Other!"(" stuff`, `Other!")"`
			]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4`,
			true), [`4`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4, f(4)`,
			true), [`4`, `f(4)`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4, ["a"], JSONValue(["b": JSONValue("c")]), recursive(func, call!s()), "texts )\"(too"`,
			true), [
			`4`, `["a"]`, `JSONValue(["b": JSONValue("c")])`,
			`recursive(func, call!s())`, `"texts )\"(too"`
			]);
}

/// Provide snippets in auto-completion
__gshared bool doCompleteSnippets = false;

// === Protocol Methods starting here ===

@protocolMethod("textDocument/completion")
CompletionList provideComplete(TextDocumentPositionParams params)
{
	Document document = documents[params.textDocument.uri];
	auto instance = activeInstance = backend.getBestInstance(document.uri.uriToFile);
	trace("Completing from instance ", instance ? instance.cwd : "null");

	if (document.uri.toLower.endsWith("dscanner.ini"))
	{
		auto possibleFields = backend.get!DscannerComponent.listAllIniFields;
		auto line = document.lineAt(params.position).strip;
		auto defaultList = CompletionList(false, possibleFields.map!(a => CompletionItem(a.name,
				CompletionItemKind.field.opt, Optional!string.init,
				MarkupContent(a.documentation).opt, Optional!bool.init, Optional!bool.init,
				Optional!string.init, Optional!string.init, (a.name ~ '=').opt)).array);
		if (!line.length)
			return defaultList;
		if (line[0] == '[')
			return CompletionList(false, [
					CompletionItem("analysis.config.StaticAnalysisConfig",
						CompletionItemKind.keyword.opt),
					CompletionItem("analysis.config.ModuleFilters", CompletionItemKind.keyword.opt, Optional!string.init,
						MarkupContent("In this optional section a comma-separated list of inclusion and exclusion"
						~ " selectors can be specified for every check on which selective filtering"
						~ " should be applied. These given selectors match on the module name and"
						~ " partial matches (std. or .foo.) are possible. Moreover, every selectors"
						~ " must begin with either + (inclusion) or - (exclusion). Exclusion selectors"
						~ " take precedence over all inclusion operators.").opt)
					]);
		auto eqIndex = line.indexOf('=');
		auto quotIndex = line.lastIndexOf('"');
		if (quotIndex != -1 && params.position.character >= quotIndex)
			return CompletionList.init;
		if (params.position.character < eqIndex)
			return defaultList;
		else
			return CompletionList(false, [
					CompletionItem(`"disabled"`, CompletionItemKind.value.opt,
						"Check is disabled".opt),
					CompletionItem(`"enabled"`, CompletionItemKind.value.opt,
						"Check is enabled".opt),
					CompletionItem(`"skip-unittest"`, CompletionItemKind.value.opt,
						"Check is enabled but not operated in the unittests".opt)
					]);
	}
	else
	{
		if (!instance)
			return CompletionList.init;

		if (document.languageId == "d")
			return provideDSourceComplete(params, instance, document);
		else if (document.languageId == "diet")
			return provideDietSourceComplete(params, instance, document);
		else if (document.languageId == "dml")
			return provideDMLSourceComplete(params, instance, document);
		else
			return CompletionList.init;
	}
}

CompletionList provideDMLSourceComplete(TextDocumentPositionParams params,
		WorkspaceD.Instance instance, ref Document document)
{
	import workspaced.com.dlangui : DlanguiComponent, CompletionType;

	CompletionList ret;

	auto items = backend.get!DlanguiComponent.complete(document.rawText,
			cast(int) document.positionToBytes(params.position)).getYield();
	ret.items.length = items.length;
	foreach (i, item; items)
	{
		CompletionItem translated;

		translated.sortText = ((item.type == CompletionType.Class ? "1." : "0.") ~ item.value).opt;
		translated.label = item.value;
		if (item.documentation.length)
			translated.documentation = MarkupContent(item.documentation).opt;
		if (item.enumName.length)
			translated.detail = item.enumName.opt;

		switch (item.type)
		{
		case CompletionType.Class:
			translated.kind = CompletionItemKind.class_;
			break;
		case CompletionType.String:
			translated.kind = CompletionItemKind.value;
			break;
		case CompletionType.Number:
			translated.kind = CompletionItemKind.value;
			break;
		case CompletionType.Color:
			translated.kind = CompletionItemKind.color;
			break;
		case CompletionType.EnumDefinition:
			translated.kind = CompletionItemKind.enum_;
			break;
		case CompletionType.EnumValue:
			translated.kind = CompletionItemKind.enumMember;
			break;
		case CompletionType.Rectangle:
			translated.kind = CompletionItemKind.typeParameter;
			break;
		case CompletionType.Boolean:
			translated.kind = CompletionItemKind.constant;
			break;
		case CompletionType.Keyword:
			translated.kind = CompletionItemKind.keyword;
			break;
		default:
		case CompletionType.Undefined:
			break;
		}

		ret.items[i] = translated;
	}

	return ret;
}

CompletionList provideDietSourceComplete(TextDocumentPositionParams params,
		WorkspaceD.Instance instance, ref Document document)
{
	import served.utils.diet;
	import dc = dietc.complete;

	auto completion = updateDietFile(document.uri.uriToFile, document.rawText.idup);

	size_t offset = document.positionToBytes(params.position);
	auto raw = completion.completeAt(offset);
	CompletionItem[] ret;

	if (raw is dc.Completion.completeD)
	{
		auto d = workspace(params.textDocument.uri).config.d;
		string code;
		contextExtractD(completion, offset, code, offset, d.dietContextCompletion);
		if (offset <= code.length && instance.has!DCDComponent)
		{
			info("DCD Completing Diet for ", code, " at ", offset);
			auto dcd = instance.get!DCDComponent.listCompletion(code, cast(int) offset).getYield;
			if (dcd.type == DCDCompletions.Type.identifiers)
			{
				ret = dcd.identifiers.convertDCDIdentifiers(d.argumentSnippets, d.completeNoDupes);
			}
		}
	}
	else
		ret = raw.map!((a) {
			CompletionItem ret;
			ret.label = a.text;
			ret.kind = a.type.mapToCompletionItemKind.opt;
			if (a.definition.length)
				ret.detail = a.definition.opt;
			if (a.documentation.length)
				ret.documentation = MarkupContent(a.documentation).opt;
			if (a.preselected)
				ret.preselect = true.opt;
			return ret;
		}).array;

	return CompletionList(false, ret);
}

CompletionList provideDSourceComplete(TextDocumentPositionParams params,
		WorkspaceD.Instance instance, ref Document document)
{
	auto lineRange = document.lineByteRangeAt(params.position.line);
	auto byteOff = cast(int) document.positionToBytes(params.position);

	string line = document.rawText[lineRange[0] .. lineRange[1]].idup;
	string prefix = line[0 .. min($, params.position.character)].strip;
	CompletionItem[] completion;
	if (document.rawText.isInComment(byteOff, backend))
		if (prefix.startsWith("///", "*", "+"))
		{
			int prefixLen = prefix[0] == '/' ? 3 : 1;
			auto remaining = prefix[prefixLen .. $].stripLeft;

			foreach (compl; import("ddocs.txt").lineSplitter)
			{
				if (compl.startsWith(remaining))
				{
					auto item = CompletionItem(compl, CompletionItemKind.snippet.opt);
					item.insertText = compl ~ ": ";
					completion ~= item;
				}
			}
			return CompletionList(false, completion);
		}
	const config = workspace(params.textDocument.uri).config;
	DCDCompletions result = DCDCompletions.empty;
	joinAll({
		if (instance.has!DCDComponent)
			result = instance.get!DCDComponent.listCompletion(document.rawText, byteOff).getYield;
	}, {
		if (instance.has!DscannerComponent)
			provideDocComplete(params, instance, document, completion, line, lineRange);
	}, {
		if (doCompleteSnippets && instance.has!SnippetsComponent)
			provideSnippetComplete(params, instance, document, config, completion, byteOff);
	});
	switch (result.type)
	{
	case DCDCompletions.Type.identifiers:
		auto d = config.d;
		completion ~= convertDCDIdentifiers(result.identifiers, d.argumentSnippets, d.completeNoDupes);
		goto case;
	case DCDCompletions.Type.calltips:
		return CompletionList(false, completion);
	default:
		throw new Exception("Unexpected result from DCD:\n\t" ~ result.raw.join("\n\t"));
	}
}

private void provideDocComplete(TextDocumentPositionParams params, WorkspaceD.Instance instance,
		ref Document document, ref CompletionItem[] completion, string line, size_t[2] lineRange)
{
	string lineStripped = line.strip;
	if (lineStripped.among!("", "/", "/*", "/+", "//", "///", "/**", "/++"))
	{
		auto defs = instance.get!DscannerComponent.listDefinitions(uriToFile(
				params.textDocument.uri), document.rawText[lineRange[1] .. $]).getYield;
		ptrdiff_t di = -1;
		FuncFinder: foreach (i, def; defs)
		{
			if (def.line >= 0 && def.line <= 5)
			{
				di = i;
				break FuncFinder;
			}
		}
		if (di == -1)
			return;
		auto def = defs[di];
		auto sig = "signature" in def.attributes;
		if (!sig)
		{
			CompletionItem doc = CompletionItem("///");
			doc.kind = CompletionItemKind.snippet;
			doc.insertTextFormat = InsertTextFormat.snippet;
			auto eol = document.eolAt(params.position.line).toString;
			doc.insertText = "/// ";
			CompletionItem doc2 = doc;
			CompletionItem doc3 = doc;
			doc2.label = "/**";
			doc2.insertText = "/** " ~ eol ~ " * $0" ~ eol ~ " */";
			doc3.label = "/++";
			doc3.insertText = "/++ " ~ eol ~ " * $0" ~ eol ~ " +/";

			completion.addDocComplete(doc, lineStripped);
			completion.addDocComplete(doc2, lineStripped);
			completion.addDocComplete(doc3, lineStripped);
			return;
		}
		auto funcArgs = extractFunctionParameters(*sig);
		string[] docs;
		if (def.name.matchFirst(ctRegex!`^[Gg]et([^a-z]|$)`))
			docs ~= "Gets $0";
		else if (def.name.matchFirst(ctRegex!`^[Ss]et([^a-z]|$)`))
			docs ~= "Sets $0";
		else if (def.name.matchFirst(ctRegex!`^[Ii]s([^a-z]|$)`))
			docs ~= "Checks if $0";
		else
			docs ~= "$0";
		int argNo = 1;
		foreach (arg; funcArgs)
		{
			auto space = arg.lastIndexOf(' ');
			if (space == -1)
				continue;
			auto identifier = arg[space + 1 .. $];
			if (!identifier.matchFirst(ctRegex!`[a-zA-Z_][a-zA-Z0-9_]*`))
				continue;
			if (argNo == 1)
				docs ~= "Params:";
			docs ~= text("  ", identifier, " = $", argNo.to!string);
			argNo++;
		}
		auto retAttr = "return" in def.attributes;
		if (retAttr && *retAttr != "void")
		{
			docs ~= "Returns: $" ~ argNo.to!string;
			argNo++;
		}
		auto depr = "deprecation" in def.attributes;
		if (depr)
		{
			docs ~= "Deprecated: $" ~ argNo.to!string ~ *depr;
			argNo++;
		}
		CompletionItem doc = CompletionItem("///");
		doc.kind = CompletionItemKind.snippet;
		doc.insertTextFormat = InsertTextFormat.snippet;
		auto eol = document.eolAt(params.position.line).toString;
		doc.insertText = docs.map!(a => "/// " ~ a).join(eol);
		CompletionItem doc2 = doc;
		CompletionItem doc3 = doc;
		doc2.label = "/**";
		doc2.insertText = "/** " ~ eol ~ docs.map!(a => " * " ~ a ~ eol).join() ~ " */";
		doc3.label = "/++";
		doc3.insertText = "/++ " ~ eol ~ docs.map!(a => " + " ~ a ~ eol).join() ~ " +/";

		completion.addDocComplete(doc, lineStripped);
		completion.addDocComplete(doc2, lineStripped);
		completion.addDocComplete(doc3, lineStripped);
	}
}

private void provideSnippetComplete(TextDocumentPositionParams params, WorkspaceD.Instance instance,
		ref Document document, ref const UserConfiguration config,
		ref CompletionItem[] completion, int byteOff)
{
	auto snippets = instance.get!SnippetsComponent;
	auto ret = snippets.getSnippetsYield(document.uri.uriToFile, document.rawText, byteOff);
	trace("got ", ret.snippets.length, " snippets fitting in this context: ",
			ret.snippets.map!"a.shortcut");
	auto eol = document.eolAt(0);
	foreach (Snippet snippet; ret.snippets)
	{
		auto item = snippet.snippetToCompletionItem;
		item.data["level"] = JSONValue(ret.info.level.to!string);
		item.data["format"] = toJSON(generateDfmtArgs(config, eol));
		item.data["params"] = toJSON(params);
		completion ~= item;
	}
}

private void addDocComplete(ref CompletionItem[] completion, CompletionItem doc, string prefix)
{
	if (!doc.label.startsWith(prefix))
		return;
	if (prefix.length > 0)
		doc.insertText = doc.insertText[prefix.length .. $];
	completion ~= doc;
}

private bool isInComment(scope const(char)[] code, size_t at, WorkspaceD backend)
{
	if (!backend)
		return false;

	import dparse.lexer : DLexer, LexerConfig, StringBehavior, tok;

	// TODO: does this kind of token parsing belong in serve-d?

	LexerConfig config;
	config.fileName = "stdin";
	config.stringBehavior = StringBehavior.source;
	auto lexer = DLexer(code, config, &backend.stringCache);

	while (!lexer.empty) switch (lexer.front.type)
	{
	case tok!"comment":
		auto t = lexer.front;

		if (lexer.front.text.startsWith("//"))
		{
			if (t.index <= at && t.index + t.text.length >= at)
				return true;
		}
		else
		{
			if (t.index <= at && t.index + t.text.length > at)
				return true;
		}

		lexer.popFront();
		break;
	case tok!"__EOF__":
		return false;
	default:
		lexer.popFront();
		break;
	}
	return false;
}

@protocolMethod("completionItem/resolve")
CompletionItem resolveCompletionItem(CompletionItem item)
{
	auto data = item.data;

	if (item.insertTextFormat.get == InsertTextFormat.snippet
			&& item.kind.get == CompletionItemKind.snippet && data.type == JSONType.object)
	{
		const resolved = "resolved" in data.object;
		if (resolved.type != JSONType.true_)
		{
			TextDocumentPositionParams params = data.object["params"]
				.fromJSON!TextDocumentPositionParams;

			Document document = documents[params.textDocument.uri];
			auto f = document.uri.uriToFile;
			auto instance = backend.getBestInstance(f);

			if (instance.has!SnippetsComponent)
			{
				auto snippets = instance.get!SnippetsComponent;
				auto snippet = snippetFromCompletionItem(item);
				snippet = snippets.resolveSnippet(f, document.rawText,
						cast(int) document.positionToBytes(params.position), snippet).getYield;
				item = snippetToCompletionItem(snippet);
			}
		}

		if (const format = "format" in data.object)
		{
			auto args = (*format).fromJSON!(string[]);
			if (item.insertTextFormat.get == InsertTextFormat.snippet)
			{
				SnippetLevel level = SnippetLevel.global;
				if (const levelStr = "level" in data.object)
					level = levelStr.str.to!SnippetLevel;
				item.insertText = formatSnippet(item.insertText.get, args, level).opt;
			}
			else
			{
				item.insertText = formatCode(item.insertText.get, args).opt;
			}
		}

		// TODO: format code
		return item;
	}
	else
	{
		return item;
	}
}

CompletionItem snippetToCompletionItem(Snippet snippet)
{
	CompletionItem item;
	item.label = snippet.shortcut;
	item.detail = snippet.title.opt;
	item.kind = CompletionItemKind.snippet.opt;
	item.documentation = MarkupContent(MarkupKind.markdown,
			snippet.documentation ~ "\n\n```d\n" ~ snippet.snippet ~ "\n```\n");
	item.filterText = snippet.shortcut.opt;
	if (capabilities.textDocument.completion.completionItem.snippetSupport)
	{
		item.insertText = snippet.snippet.opt;
		item.insertTextFormat = InsertTextFormat.snippet.opt;
	}
	else
		item.insertText = snippet.plain.opt;

	item.data = JSONValue([
			"resolved": JSONValue(snippet.resolved),
			"id": JSONValue(snippet.id),
			"providerId": JSONValue(snippet.providerId),
			"data": snippet.data
			]);
	return item;
}

Snippet snippetFromCompletionItem(CompletionItem item)
{
	Snippet snippet;
	snippet.shortcut = item.label;
	snippet.title = item.detail.get;
	snippet.documentation = item.documentation.get.value;
	auto end = snippet.documentation.lastIndexOf("\n\n```d\n");
	if (end != -1)
		snippet.documentation = snippet.documentation[0 .. end];

	if (capabilities.textDocument.completion.completionItem.snippetSupport)
		snippet.snippet = item.insertText.get;
	else
		snippet.plain = item.insertText.get;

	snippet.resolved = item.data["resolved"].boolean;
	snippet.id = item.data["id"].str;
	snippet.providerId = item.data["providerId"].str;
	snippet.data = item.data["data"];
	return snippet;
}

unittest
{
	auto backend = new WorkspaceD();
	assert(isInComment(`hello /** world`, 10, backend));
	assert(!isInComment(`hello /** world`, 3, backend));
	assert(isInComment(`hello /* world */ bar`, 8, backend));
	assert(isInComment(`hello /* world */ bar`, 16, backend));
	assert(!isInComment(`hello /* world */ bar`, 17, backend));
	assert(!isInComment("int x;\n// line comment\n", 6, backend));
	assert(isInComment("int x;\n// line comment\n", 7, backend));
	assert(isInComment("int x;\n// line comment\n", 9, backend));
	assert(isInComment("int x;\n// line comment\n", 21, backend));
	assert(isInComment("int x;\n// line comment\n", 22, backend));
	assert(!isInComment("int x;\n// line comment\n", 23, backend));
}

auto convertDCDIdentifiers(DCDIdentifier[] identifiers, bool argumentSnippets, bool completeNoDupes)
{
	CompletionItem[] completion;
	foreach (identifier; identifiers)
	{
		CompletionItem item;
		item.label = identifier.identifier;
		item.kind = identifier.type.convertFromDCDType;
		if (identifier.documentation.length)
			item.documentation = MarkupContent(identifier.documentation.ddocToMarked);
		if (identifier.definition.length)
		{
			item.detail = identifier.definition;
			if (!completeNoDupes)
				item.sortText = identifier.definition;
			// TODO: only add arguments when this is a function call, eg not on template arguments
			if (identifier.type == "f" && argumentSnippets)
			{
				item.insertTextFormat = InsertTextFormat.snippet;
				string args;
				auto parts = identifier.definition.extractFunctionParameters;
				if (parts.length)
				{
					int numRequired;
					foreach (i, part; parts)
					{
						ptrdiff_t equals = part.indexOf('=');
						if (equals != -1)
						{
							part = part[0 .. equals].stripRight;
							// remove default value from autocomplete
						}
						auto space = part.lastIndexOf(' ');
						if (space != -1)
							part = part[space + 1 .. $];

						if (args.length)
							args ~= ", ";
						args ~= "${" ~ (i + 1).to!string ~ ":" ~ part ~ "}";
						numRequired++;
					}
					item.insertText = identifier.identifier ~ "(${0:" ~ args ~ "})";
				}
			}
		}
		completion ~= item;
	}

	completion.sort!"a.label < b.label";
	if (completeNoDupes)
		return completion.chunkBy!((a, b) => a.label == b.label && a.kind == b.kind)
			.map!((a) {
				CompletionItem ret = a.front;
				auto details = a.map!"a.detail"
					.filter!"!a.isNull && a.value.length"
					.uniq
					.array;
				auto docs = a.map!"a.documentation"
					.filter!"!a.isNull && a.value.value.length"
					.uniq
					.array;
				bool isMarkdown = docs.any!(a => a.kind == MarkupKind.markdown);
				if (docs.length)
					ret.documentation = MarkupContent(isMarkdown ? MarkupKind.markdown
						: MarkupKind.plaintext, docs.map!"a.value.value".join("\n\n"));
				if (details.length)
					ret.detail = details.map!"a.value".join("\n");
				return ret;
			})
			.array;
	else
		return completion.chunkBy!((a, b) => a.label == b.label && a.detail == b.detail
				&& a.kind == b.kind)
			.map!((a) {
				CompletionItem ret = a.front;
				auto docs = a.map!"a.documentation"
					.filter!"!a.isNull && a.value.value.length"
					.uniq
					.array;
				bool isMarkdown = docs.any!(a => a.kind == MarkupKind.markdown);
				if (docs.length)
					ret.documentation = MarkupContent(isMarkdown ? MarkupKind.markdown
						: MarkupKind.plaintext, docs.map!"a.value.value".join("\n\n"));
				return ret;
			})
			.array;
}

// === Protocol Notifications starting here ===

/// Restarts all DCD servers started by this serve-d instance. Returns `true` once done.
@protocolMethod("served/restartServer")
bool restartServer()
{
	Future!void[] fut;
	foreach (instance; backend.instances)
		if (instance.has!DCDComponent)
			fut ~= instance.get!DCDComponent.restartServer();
	joinAll(fut);
	return true;
}

/// Kills all DCD servers started by this serve-d instance.
@protocolNotification("served/killServer")
void killServer()
{
	foreach (instance; backend.instances)
		if (instance.has!DCDComponent)
			instance.get!DCDComponent.killServer();
}

/// Registers a snippet across the whole serve-d application which may be limited to given grammatical scopes.
/// Requires `--provide context-snippets`
/// Returns: `false` if SnippetsComponent hasn't been loaded yet, otherwise `true`.
@protocolMethod("served/addDependencySnippet")
bool addDependencySnippet(AddDependencySnippetParams params)
{
	if (!backend.has!SnippetsComponent)
		return false;
	PlainSnippet snippet;
	foreach (i, ref v; snippet.tupleof)
	{
		static assert(__traits(identifier, snippet.tupleof[i]) == __traits(identifier,
				params.snippet.tupleof[i]),
				"struct definition changed without updating SerializablePlainSnippet");
		// convert enums
		v = cast(typeof(v)) params.snippet.tupleof[i];
	}
	backend.get!SnippetsComponent.addDependencySnippet(params.requiredDependencies, snippet);
	return true;
}
