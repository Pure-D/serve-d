module served.commands.complete;

import served.ddoc;
import served.extension;
import served.fibermanager;
import served.types;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.coms;

import std.array : array;
import std.algorithm : reverse, map, canFind, endsWith, min;
import std.conv : to;
import std.experimental.logger;
import std.regex : matchFirst, ctRegex;
import std.string : toLower, lastIndexOf, strip, indexOf, lineSplitter, join;

import fs = std.file;
import io = std.stdio;

CompletionItemKind convertFromDCDType(string type)
{
	switch (type)
	{
	case "c":
		return CompletionItemKind.class_;
	case "i":
		return CompletionItemKind.interface_;
	case "s":
	case "u":
		return CompletionItemKind.unit;
	case "a":
	case "A":
	case "v":
		return CompletionItemKind.variable;
	case "m":
	case "e":
		return CompletionItemKind.field;
	case "k":
		return CompletionItemKind.keyword;
	case "f":
		return CompletionItemKind.function_;
	case "g":
		return CompletionItemKind.enum_;
	case "P":
	case "M":
		return CompletionItemKind.module_;
	case "l":
		return CompletionItemKind.reference;
	case "t":
	case "T":
		return CompletionItemKind.property;
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

string substr(T)(string s, T start, T end)
{
	if (!s.length)
		return "";
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

string[] extractFunctionParameters(string sig, bool exact = false)
{
	if (!sig.length)
		return [];
	string[] params;
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
			params ~= sig.substr(i + 1, paramEnd).strip;
			paramEnd = i;
			i--;
			break;
		case ';':
		case '(':
			auto param = sig.substr(i + 1, paramEnd).strip;
			if (param.length)
				params ~= param;
			reverse(params);
			return params;
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
	reverse(params);
	return params;
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
			["T a", "T b", "string[string] map", `Other!"(" stuff1`,
			`SomeType!(double, ")double") myType`, `Other!"(" stuff`, `Other!")"`]);
	assertEqual(extractFunctionParameters(`SomeType!(int,"int_")foo(T,Args...)(T a,T b,string[string] map,Other!"(" stuff1,SomeType!(double,")double")myType,Other!"(" stuff,Other!")")`),
			["T a", "T b", "string[string] map", `Other!"(" stuff1`,
			`SomeType!(double,")double")myType`, `Other!"(" stuff`, `Other!")"`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4`,
			true), [`4`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4, f(4)`,
			true), [`4`, `f(4)`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4, ["a"], JSONValue(["b": JSONValue("c")]), recursive(func, call!s()), "texts )\"(too"`,
			true), [`4`, `["a"]`, `JSONValue(["b": JSONValue("c")])`,
			`recursive(func, call!s())`, `"texts )\"(too"`]);
}

// === Protocol Methods starting here ===

@protocolMethod("textDocument/completion")
CompletionList provideComplete(TextDocumentPositionParams params)
{
	import painlessjson : fromJSON;

	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	Document document = documents[params.textDocument.uri];
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
		//dfmt off
		if (line[0] == '[')
			return CompletionList(false, [
				CompletionItem("analysis.config.StaticAnalysisConfig", CompletionItemKind.keyword.opt),
				CompletionItem("analysis.config.ModuleFilters", CompletionItemKind.keyword.opt, Optional!string.init,
					MarkupContent("In this optional section a comma-separated list of inclusion and exclusion"
					~ " selectors can be specified for every check on which selective filtering"
					~ " should be applied. These given selectors match on the module name and"
					~ " partial matches (std. or .foo.) are possible. Moreover, every selectors"
					~ " must begin with either + (inclusion) or - (exclusion). Exclusion selectors"
					~ " take precedence over all inclusion operators.").opt)
			]);
		//dfmt on
		auto eqIndex = line.indexOf('=');
		auto quotIndex = line.lastIndexOf('"');
		if (quotIndex != -1 && params.position.character >= quotIndex)
			return CompletionList.init;
		if (params.position.character < eqIndex)
			return defaultList;
		else//dfmt off
			return CompletionList(false, [
				CompletionItem(`"disabled"`, CompletionItemKind.value.opt, "Check is disabled".opt),
				CompletionItem(`"enabled"`, CompletionItemKind.value.opt, "Check is enabled".opt),
				CompletionItem(`"skip-unittest"`, CompletionItemKind.value.opt,
					"Check is enabled but not operated in the unittests".opt)
			]);
		//dfmt on
	}
	else
	{
		if (document.languageId == "d")
			return provideDSourceComplete(params, workspaceRoot, document);
		else if (document.languageId == "diet")
			return provideDietSourceComplete(params, workspaceRoot, document);
		else
			return CompletionList.init;
	}
}

CompletionList provideDietSourceComplete(TextDocumentPositionParams params,
		string workspaceRoot, ref Document document)
{
	import served.diet;
	import dc = dietc.complete;

	auto completion = updateDietFile(document.uri.uriToFile, workspaceRoot, document.text);

	size_t offset = document.positionToBytes(params.position);
	auto raw = completion.completeAt(offset);
	CompletionItem[] ret;

	if (raw is dc.Completion.completeD)
	{
		string code;
		dc.extractD(completion, offset, code, offset);
		if (offset <= code.length && backend.has!DCDComponent(workspaceRoot))
		{
			info("DCD Completing Diet for ", code, " at ", offset);
			auto dcd = backend.get!DCDComponent(workspaceRoot).listCompletion(code,
					cast(int) offset).getYield;
			if (dcd.type == DCDCompletions.Type.identifiers)
				ret = dcd.identifiers.convertDCDIdentifiers(workspace(params.textDocument.uri)
						.config.d.argumentSnippets);
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
		string workspaceRoot, ref Document document)
{
	string line = document.lineAt(params.position);
	string prefix = line[0 .. min($, params.position.character)];
	CompletionItem[] completion;
	if (prefix.strip == "///" || prefix.strip == "*")
	{
		foreach (compl; import("ddocs.txt").lineSplitter)
		{
			auto item = CompletionItem(compl, CompletionItemKind.snippet.opt);
			item.insertText = compl ~ ": ";
			completion ~= item;
		}
		return CompletionList(false, completion);
	}
	auto byteOff = cast(int) document.positionToBytes(params.position);
	DCDCompletions result = DCDCompletions.empty;
	joinAll({
		if (backend.has!DCDComponent(workspaceRoot))
			result = backend.get!DCDComponent(workspaceRoot)
				.listCompletion(document.text, byteOff).getYield;
	}, {
		if (!line.strip.length)
		{
			auto defs = backend.get!DscannerComponent(workspaceRoot)
				.listDefinitions(uriToFile(params.textDocument.uri), document.text).getYield;
			ptrdiff_t di = -1;
			FuncFinder: foreach (i, def; defs)
			{
				for (int n = 1; n < 5; n++)
					if (def.line == params.position.line + n)
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
				doc2.label = "/**";
				doc2.insertText = "/** " ~ eol ~ " * $0" ~ eol ~ " */";
				completion ~= doc;
				completion ~= doc2;
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
				string identifier = arg[space + 1 .. $];
				if (!identifier.matchFirst(ctRegex!`[a-zA-Z_][a-zA-Z0-9_]*`))
					continue;
				if (argNo == 1)
					docs ~= "Params:";
				docs ~= "  " ~ identifier ~ " = $" ~ argNo.to!string;
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
			doc2.label = "/**";
			doc2.insertText = "/** " ~ eol ~ docs.map!(a => " * " ~ a ~ eol).join() ~ " */";
			completion ~= doc;
			completion ~= doc2;
		}
	});
	switch (result.type)
	{
	case DCDCompletions.Type.identifiers:
		completion = convertDCDIdentifiers(result.identifiers,
				workspace(params.textDocument.uri).config.d.argumentSnippets);
		goto case;
	case DCDCompletions.Type.calltips:
		return CompletionList(false, completion);
	default:
		throw new Exception("Unexpected result from DCD:\n\t" ~ result.raw.join("\n\t"));
	}
}

auto convertDCDIdentifiers(DCDIdentifier[] identifiers, lazy bool argumentSnippets)
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
			item.sortText = identifier.definition;
			// TODO: only add arguments when this is a function call, eg not on template arguments
			if (identifier.type == "f" && argumentSnippets)
			{
				item.insertTextFormat = InsertTextFormat.snippet;
				string args;
				auto parts = identifier.definition.extractFunctionParameters;
				if (parts.length)
				{
					bool isOptional;
					string[] optionals;
					int numRequired;
					foreach (i, part; parts)
					{
						if (!isOptional)
							isOptional = part.canFind('=');
						if (isOptional)
							optionals ~= part;
						else
						{
							if (args.length)
								args ~= ", ";
							args ~= "${" ~ (i + 1).to!string ~ ":" ~ part ~ "}";
							numRequired++;
						}
					}
					foreach (i, part; optionals)
					{
						if (args.length)
							part = ", " ~ part;
						// Go through optionals in reverse
						args ~= "${" ~ (numRequired + optionals.length - i).to!string ~ ":" ~ part ~ "}";
					}
					item.insertText = identifier.identifier ~ "(${0:" ~ args ~ "})";
				}
			}
		}
		completion ~= item;
	}
	return completion;
}

// === Protocol Notifications starting here ===

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

@protocolNotification("served/killServer")
void killServer()
{
	foreach (instance; backend.instances)
		if (instance.has!DCDComponent)
			instance.get!DCDComponent.killServer();
}
