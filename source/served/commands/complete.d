module served.commands.complete;

import served.commands.format : formatCode, formatSnippet;
import served.extension;
import served.types;
import served.utils.ddoc;
import served.utils.fibermanager;

import workspaced.api;
import workspaced.com.dfmt : DfmtComponent;
import workspaced.com.dcd;
import workspaced.com.dcdext;
import workspaced.com.snippets;
import workspaced.com.importer;
import workspaced.com.index;
import workspaced.coms;
import workspaced.helpers : isValidDIdentifier, isDIdentifierSeparatingChar;

import std.algorithm : among, any, canFind, chunkBy, endsWith, filter, findSplit,
	map, min, reverse, sort, startsWith, uniq;
import std.array : appender, array, split;
import std.conv : text, to;
import std.experimental.logger;
import std.format : format;
import std.string : indexOf, join, lastIndexOf, lineSplitter, strip, stripLeft,
	stripRight, toLower;
import std.utf : decodeFront;

import dparse.lexer : Token;

import fs = std.file;
import io = std.stdio;

static immutable sortPrefixDoc = "0_";
static immutable sortPrefixSnippets = "2_5_";
// dcd additionally sorts inside with sortFromDCDType return value (appends to this)
static immutable sortPrefixDCD = "2_";
// additional sorting inside with already imported values = 0_, std.* = 1_, core.* & etc.* = 2_
static immutable sortPrefixAutoImport = "3_";

CompletionItemKind convertFromDCDType(string type)
{
	if (type.length != 1)
		return CompletionItemKind.text;

	switch (type[0])
	{
	case 'c': // class name
		return CompletionItemKind.class_;
	case 'i': // interface name
		return CompletionItemKind.interface_;
	case 's': // struct name
	case 'u': // union name
		return CompletionItemKind.struct_;
	case 'a': // array
	case 'A': // associative array
	case 'v': // variable name
		return CompletionItemKind.variable;
	case 'm': // member variable
		return CompletionItemKind.field;
	case 'e': // enum member
		return CompletionItemKind.enumMember;
	case 'k': // keyword
		return CompletionItemKind.keyword;
	case 'f': // function
		return CompletionItemKind.function_;
	case 'F': // UFCS function acts like a method
		return CompletionItemKind.method;
	case 'g': // enum name
		return CompletionItemKind.enum_;
	case 'P': // package name
	case 'M': // module name
		return CompletionItemKind.module_;
	case 'l': // alias name
		return CompletionItemKind.reference;
	case 't': // template name
	case 'T': // mixin template name
		return CompletionItemKind.property;
	case 'h': // template type parameter
	case 'p': // template variadic parameter
		return CompletionItemKind.typeParameter;
	default:
		return CompletionItemKind.text;
	}
}

string sortFromDCDType(string type)
{
	if (type.length != 1)
		return "9_";

	switch (type[0])
	{
	case 'v': // variable name
		return "2_";
	case 'm': // member variable
		return "3_";
	case 'f': // function
	case 'F': // UFCS function
		return "4_";
	case 'k': // keyword
	case 'e': // enum member
		return "5_";
	case 'c': // class name
	case 'i': // interface name
	case 's': // struct name
	case 'u': // union name
	case 'a': // array
	case 'A': // associative array
	case 'g': // enum name
	case 'P': // package name
	case 'M': // module name
	case 'l': // alias name
	case 't': // template name
	case 'T': // mixin template name
	case 'h': // template type parameter
	case 'p': // template variadic parameter
		return "6_";
	default:
		return "9_";
	}
}

SymbolKind convertFromDCDSearchType(string type)
{
	if (type.length != 1)
		return cast(SymbolKind) 0;
	switch (type[0])
	{
	case 'c':
		return SymbolKind.class_;
	case 'i':
		return SymbolKind.interface_;
	case 's':
	case 'u':
		return SymbolKind.package_;
	case 'a':
	case 'A':
	case 'v':
		return SymbolKind.variable;
	case 'm':
	case 'e':
		return SymbolKind.field;
	case 'f':
	case 'l':
		return SymbolKind.function_;
	case 'F':
		return SymbolKind.method;
	case 'g':
		return SymbolKind.enum_;
	case 'P':
	case 'M':
		return SymbolKind.namespace;
	case 't':
	case 'T':
		return SymbolKind.property;
	case 'k':
	default:
		return cast(SymbolKind) 0;
	}
}

SymbolKind convertFromDscannerType(char type, string name = null)
{
	switch (type)
	{
	case 'c':
		return SymbolKind.class_;
	case 's':
		return SymbolKind.struct_;
	case 'i':
		return SymbolKind.interface_;
	case 'T':
		return SymbolKind.property;
	case 'f':
	case 'U':
	case 'Q':
	case 'W':
	case 'P':
	case 'N':
		if (name == "this")
			return SymbolKind.constructor;
		else
			return SymbolKind.function_;
	case 'C':
	case 'S':
		return SymbolKind.constructor;
	case 'g':
		return SymbolKind.enum_;
	case 'u':
		return SymbolKind.struct_;
	case 'D':
	case 'V':
	case 'e':
		return SymbolKind.constant;
	case 'v':
		return SymbolKind.variable;
	case 'a':
		return SymbolKind.field;
	case ':':
		return SymbolKind.module_;
	default:
		return cast(SymbolKind) 0;
	}
}

SymbolKindEx convertExtendedFromDscannerType(char type)
{
	switch (type)
	{
	case 'U':
		return SymbolKindEx.test;
	case 'D':
		return SymbolKindEx.debugSpec;
	case 'V':
		return SymbolKindEx.versionSpec;
	case 'C':
		return SymbolKindEx.staticCtor;
	case 'S':
		return SymbolKindEx.sharedStaticCtor;
	case 'Q':
		return SymbolKindEx.staticDtor;
	case 'W':
		return SymbolKindEx.sharedStaticDtor;
	case 'P':
		return SymbolKindEx.postblit;
	default:
		return cast(SymbolKindEx) 0;
	}
}

CompletionItemKind convertCompletionFromDScannerType(char type)
{
	switch (type)
	{
	case 'c':
		return CompletionItemKind.class_;
	case 's':
		return CompletionItemKind.struct_;
	case 'i':
		return CompletionItemKind.interface_;
	case 'T':
		return CompletionItemKind.property;
	case 'f':
	case 'U':
	case 'Q':
	case 'W':
	case 'P':
	case 'N':
		return CompletionItemKind.function_;
	case 'C':
	case 'S':
		return CompletionItemKind.constructor;
	case 'g':
		return CompletionItemKind.enum_;
	case 'u':
		return CompletionItemKind.struct_;
	case 'D':
	case 'V':
	case 'e':
		return CompletionItemKind.constant;
	case 'v':
		return CompletionItemKind.variable;
	case 'a':
		return CompletionItemKind.field;
	default:
		return cast(CompletionItemKind) 0;
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
CalltipsSupport extractFunctionParameters(scope return const(char)[] sig, bool isDefinition, DCDExtComponent dcdext)
{
	if (!sig.length)
		return CalltipsSupport.init;
	auto pos = isDefinition ? sig.length - 1 : sig.length;
	auto ret = dcdext.extractCallParameters(sig, cast(int)pos, isDefinition);
	return ret;
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
		trace("Providing dscanner.ini completion");
		auto possibleFields = backend.get!DscannerComponent.listAllIniFields;
		scope line = document.lineAtScope(params.position).strip;
		auto defaultList = CompletionList(false, possibleFields.map!((a) {
			CompletionItem ret = {
				label: a.name,
				kind: CompletionItemKind.field,
				documentation: MarkupContent(a.documentation),
				insertText: a.name ~ '='
			};
			return ret;
		}).array);

		if (!line.length)
			return defaultList;

		if (line[0] == '[')
		{
			// ini section
			CompletionItem staticAnalysisConfig = {
				label: "analysis.config.StaticAnalysisConfig",
				kind: CompletionItemKind.keyword
			};
			CompletionItem moduleFilters = {
				label: "analysis.config.ModuleFilters",
				kind: CompletionItemKind.keyword,
				documentation: MarkupContent(
					"In this optional section a comma-separated list of inclusion and exclusion"
					~ " selectors can be specified for every check on which selective filtering"
					~ " should be applied. These given selectors match on the module name and"
					~ " partial matches (std. or .foo.) are possible. Moreover, every selectors"
					~ " must begin with either + (inclusion) or - (exclusion). Exclusion selectors"
					~ " take precedence over all inclusion operators.")
			};
			return CompletionList(false, [staticAnalysisConfig, moduleFilters]);
		}

		auto eqIndex = line.indexOf('=');
		auto quotIndex = line.lastIndexOf('"');
		if (quotIndex != -1 && params.position.character >= quotIndex)
			return CompletionList.init;
		if (params.position.character < eqIndex)
			return defaultList;
		else
		{
			CompletionItem disabled = {
				label: `"disabled"`,
				kind: CompletionItemKind.value,
				detail: "Check is disabled"
			};
			CompletionItem enabled = {
				label: `"enabled"`,
				kind: CompletionItemKind.value,
				detail: "Check is enabled"
			};
			CompletionItem skipUnittest = {
				label: `"skip-unittest"`,
				kind: CompletionItemKind.value,
				detail: "Check is enabled but not operated in the unittests"
			};
			return CompletionList(false, [disabled, enabled, skipUnittest]);
		}
	}
	else
	{
		if (!instance)
		{
			trace("Providing no completion because no instance");
			return CompletionList.init;
		}

		if (document.getLanguageId == "d")
			return provideDSourceComplete(params, instance, document);
		else if (document.getLanguageId == "diet")
			return provideDietSourceComplete(params, instance, document);
		else if (document.getLanguageId == "dml")
			return provideDMLSourceComplete(params, instance, document);
		else
		{
			tracef("Providing no completion for unknown language ID %s.", document.getLanguageId);
			return CompletionList.init;
		}
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
			translated.documentation = MarkupContent(item.documentation);
		if (item.enumName.length)
			translated.detail = item.enumName.opt;

		switch (item.type)
		{
		case CompletionType.Class:
			translated.insertTextFormat = InsertTextFormat.snippet;
			translated.insertText = item.value ~ ` {$0}`;
			break;
		case CompletionType.Color:
			translated.insertTextFormat = InsertTextFormat.snippet;
			translated.insertText = item.value ~ `: ${0:#000000}`;
			break;
		case CompletionType.String:
			translated.insertTextFormat = InsertTextFormat.snippet;
			translated.insertText = item.value ~ `: "$0"`;
			break;
		case CompletionType.EnumDefinition:
			translated.insertTextFormat = InsertTextFormat.plainText;
			translated.insertText = item.enumName ~ "." ~ item.value;
			break;
		case CompletionType.Rectangle:
		case CompletionType.Number:
			translated.insertTextFormat = InsertTextFormat.snippet;
			translated.insertText = item.value ~ `: ${0:0}`;
			break;
		case CompletionType.Keyword:
			// don't set, inherit from label
			break;
		default:
			translated.insertTextFormat = InsertTextFormat.plainText;
			translated.insertText = item.value ~ ": ";
			break;
		}

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

	auto dcdext = instance.has!DCDExtComponent ? instance.get!DCDExtComponent : null;

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
				ret = dcd.identifiers.convertDCDIdentifiers(d.argumentSnippets, dcdext);
			}
		}
	}
	else
		ret = raw.map!((a) {
			CompletionItem ret;
			ret.label = a.text;
			if (a.text.among!(`''`, `""`, "``", `{}`, `()`, `[]`, `<>`))
			{
				ret.insertTextFormat = InsertTextFormat.snippet;
				ret.insertText = a.text[0] ~ "$0" ~ a.text[1];
			}
			ret.kind = a.type.mapToCompletionItemKind.opt;
			if (a.definition.length)
			{
				ret.detail = a.definition.opt;
				if (capabilities
					.textDocument.orDefault
					.completion.orDefault
					.completionItem.orDefault
					.labelDetailsSupport.orDefault)
					ret.labelDetails = CompletionItemLabelDetails(ret.detail);
			}
			if (a.documentation.length)
				ret.documentation = MarkupContent(a.documentation);
			if (a.preselected)
				ret.preselect = true;
			return ret;
		}).array;

	return CompletionList(false, ret);
}

CompletionList provideDSourceComplete(TextDocumentPositionParams params,
		WorkspaceD.Instance instance, ref Document document)
{
	auto lineRange = document.lineByteRangeAt(params.position.line);
	auto byteOff = cast(int) document.positionToBytes(params.position);

	auto dcdext = instance.has!DCDExtComponent ? instance.get!DCDExtComponent : null;

	string line = document.rawText[lineRange[0] .. lineRange[1]].idup;
	// TODO: do UTF-16 counting instead of just relying on byte offset
	string prefix = line[0 .. min($, params.position.character)].strip;
	
	size_t idStart = prefix.length;
	while (idStart > 0 && !prefix[idStart - 1].isDIdentifierSeparatingChar)
		idStart--;
	// just the identifier before the cursor
	auto prefixIdentifier = prefix[idStart .. $];

	CompletionItem[] completion;
	Token commentToken;
	if (document.rawText.isInComment(byteOff, backend, &commentToken))
	{
		import dparse.lexer : tok;
		if (commentToken.type == tok!"__EOF__")
			return CompletionList.init;

		if (commentToken.text.startsWith("///", "/**", "/++"))
		{
			trace("Providing comment completion");
			int prefixLen = (prefix.length > 0 && prefix[0] == '/') ? 3 : 1;
			auto remaining = prefix[min($, prefixLen) .. $].stripLeft;

			foreach (compl; import("ddocs.txt").lineSplitter)
			{
				if (compl.startsWith(remaining))
				{
					CompletionItem item = {
						label: compl,
						kind: CompletionItemKind.snippet,
						insertText: compl ~ ": "
					};
					completion ~= item;
				}
			}

			// make the comment line include the new line to properly auto-complete everything
			if (document.rawText[lineRange[1] .. $].startsWith("\r", "\n"))
				lineRange[1]++;

			provideDocComplete(params, instance, document, completion, line, lineRange);

			return CompletionList(false, completion);
		}
	}

	bool completeDCD = instance.has!DCDComponent;
	bool completeDoc = instance.has!DscannerComponent;
	bool completeSnippets = doCompleteSnippets && instance.has!SnippetsComponent;
	bool completeIndex = instance.has!IndexComponent && instance.has!ImporterComponent;

	tracef("Performing regular D comment completion (DCD=%s, Documentation=%s, Snippets=%s)",
			completeDCD, completeDoc, completeSnippets);
	const config = workspace(params.textDocument.uri).config;
	DCDCompletions result = DCDCompletions.empty;
	SnippetInfo snippetInfo;
	joinAll({
		if (completeDCD)
			result = instance.get!DCDComponent.listCompletion(document.rawText, byteOff).getYield;
	}, {
		if (completeDoc)
			provideDocComplete(params, instance, document, completion, line, lineRange);
	}, {
		if (completeSnippets)
			snippetInfo = provideSnippetComplete(params, instance, document, config, completion, byteOff);
		else
			snippetInfo = getSnippetInfo(instance, document, byteOff);
	}, {
		if (completeIndex && config.d.enableIndex && config.d.enableAutoImportCompletions && prefixIdentifier.length)
			provideAutoImports(params, instance, document, completion, byteOff, prefixIdentifier);
	});

	if (completeDCD && result != DCDCompletions.init)
	{
		if (result.type == DCDCompletions.Type.identifiers)
		{
			auto d = config.d;
			completion ~= convertDCDIdentifiers(result.identifiers, d.argumentSnippets, dcdext, snippetInfo);
		}
		else if (result.type != DCDCompletions.Type.calltips)
		{
			trace("Unexpected result from DCD: ", result);
		}
	}
	return CompletionList(false, completion);
}

private void provideDocComplete(TextDocumentPositionParams params, WorkspaceD.Instance instance,
		ref Document document, ref CompletionItem[] completion, string line, size_t[2] lineRange)
{
	string lineStripped = line.strip;
	if (lineStripped.among!("", "/", "/*", "/+", "//", "///", "/**", "/++"))
	{
		auto defs = instance.get!DscannerComponent.listDefinitions(uriToFile(
				params.textDocument.uri), document.rawText[lineRange[1] .. $]).getYield
				.definitions;
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
		auto sigSlice = *sig;
		auto calltips = extractFunctionParameters(sigSlice, true, instance.get!DCDExtComponent);
		string[] docs = ["$0"];
		int argNo = 1;
		foreach (arg; calltips.templateArgs ~ calltips.functionArgs)
		{
			auto name = sigSlice[arg.nameRange[0] .. arg.nameRange[1]];
			if (!name.isValidDIdentifier)
				continue;
			if (argNo == 1)
				docs ~= "Params:";
			docs ~= text("  ", name, " = $", argNo.to!string);
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

		doc.sortText = opt(sortPrefixDoc ~ "0");
		doc2.sortText = opt(sortPrefixDoc ~ "1");
		doc3.sortText = opt(sortPrefixDoc ~ "2");

		completion.addDocComplete(doc, lineStripped);
		completion.addDocComplete(doc2, lineStripped);
		completion.addDocComplete(doc3, lineStripped);
	}
}

void provideAutoImports(TextDocumentPositionParams params, WorkspaceD.Instance instance,
		ref Document document, ref CompletionItem[] completion, int byteOff, string prefixIdentifier,
		bool exactMatch = false)
{
	IndexComponent idx = instance.get!IndexComponent;
	const availableImports = instance.get!ImporterComponent.get(document.rawText, byteOff);
	scope size_t[string] modLookup;
	foreach (n, imp; availableImports)
		modLookup[imp.name.join('.')] = n;
	auto thisModule = availableImports.definitonModule.join(".");

	scope bool[string] viaPublicImports;
	foreach (n, imp; availableImports)
	{
		idx.iteratePublicImportsRecursive(imp.name.join('.'), (parent, mod) {
			if (mod !in modLookup)
				viaPublicImports[mod] = true;
		});
	}
	tracef("via direct imports: %s depends on %s", thisModule, modLookup.byKey);
	tracef("via public imports: %s depends on %s", thisModule, viaPublicImports.byKey);

	// TODO: use previously indexed symbols from unused dependencies to
	// support adding DUB packages from imports (at least popular ones)

	idx.iterateSymbolsStartingWith(prefixIdentifier,
		(string symbol, char type, scope const ModuleRef mod) {
			if (mod == "object" || mod == thisModule || !symbol.length)
				return;
			if (exactMatch && symbol != prefixIdentifier)
				return;
			if (mod in viaPublicImports)
				return;

			string subSorter = mod.getModuleSortKey;

			if (auto hasImport = mod in modLookup)
			{
				const ImportInfo impInfo = availableImports[*hasImport];
				string prefix;
				if (impInfo.isStatic || impInfo.rename.length)
					prefix = impInfo.effectiveName;

				if (impInfo.selectives.length)
				{
					// TODO: add selective non-imported to list
				}
				else if (prefix.length)
				{
					CompletionItemLabelDetails labelDetails = {
						detail: prefix == mod
							? " (" ~ mod ~ ")"
							: " (" ~ prefix ~ " = " ~ mod ~ ")"
					};

					CompletionItem item = {
						label: symbol,
						labelDetails: labelDetails,
						detail: "use renamed import " ~ prefix,
						sortText: sortPrefixAutoImport ~ "0_" ~ subSorter ~ symbol,
						insertText: prefix ~ "." ~ symbol,
						data: JsonValue([
							"uri": JsonValue(params.textDocument.uri),
							"line": JsonValue(params.position.line),
							"column": JsonValue(params.position.character),
							"imports": JsonValue([
								JsonValue(mod)
							]),
							// moduleName is used in other contexts that depend
							// on this list. (e.g. code_actions.d)
							"moduleName": JsonValue(mod),
						]),
						kind: convertCompletionFromDScannerType(type)
					};
					completion ~= item;
				}
			}
			else
			{
				CompletionItemLabelDetails labelDetails = {
					detail: " (import " ~ mod ~ ")"
				};

				CompletionItem item = {
					label: symbol,
					labelDetails: labelDetails,
					detail: "auto-import from " ~ mod,
					sortText: sortPrefixAutoImport ~ subSorter ~ symbol,
					data: JsonValue([
						"uri": JsonValue(params.textDocument.uri),
						"line": JsonValue(params.position.line),
						"column": JsonValue(params.position.character),
						"imports": JsonValue([
							JsonValue(mod)
						]),
						// moduleName is used in other contexts that depend
						// on this list. (e.g. code_actions.d)
						"moduleName": JsonValue(mod),
					]),
					kind: convertCompletionFromDScannerType(type)
				};
				completion ~= item;
			}
		});
}

private SnippetInfo provideSnippetComplete(TextDocumentPositionParams params, WorkspaceD.Instance instance,
		ref Document document, ref const UserConfiguration config,
		ref CompletionItem[] completion, int byteOff)
{
	if (byteOff > 0 && document.rawText[byteOff - 1 .. $].startsWith("."))
		return SnippetInfo.init; // no snippets after '.' character

	auto snippets = instance.get!SnippetsComponent;
	auto ret = snippets.getSnippetsYield(document.uri.uriToFile, document.rawText, byteOff);
	trace("got ", ret.snippets.length, " snippets fitting in this context: ",
			ret.snippets.map!"a.shortcut");
	auto eol = document.eolAt(0);
	foreach (Snippet snippet; ret.snippets)
	{
		CompletionItem item = snippet.snippetToCompletionItem;
		JsonValue[string] data;
		data["level"] = JsonValue(ret.info.level.to!string);
		if (!snippet.unformatted)
			data["format"] = JsonValue(generateDfmtArgs(config, eol).join("\t"));
		data["uri"] = JsonValue(params.textDocument.uri);
		data["line"] = JsonValue(params.position.line);
		data["column"] = JsonValue(params.position.character);
		if (snippet.imports.length)
			data["imports"] = JsonValue(snippet.imports.map!(i => JsonValue(i)).array);
		item.data = JsonValue(data);
		completion ~= item;
	}

	return ret.info;
}

private SnippetInfo getSnippetInfo(WorkspaceD.Instance instance, ref Document document, int byteOff)
{
	if (byteOff > 0 && document.rawText[byteOff - 1 .. $].startsWith("."))
		return SnippetInfo.init; // no snippets after '.' character

	auto snippets = instance.get!SnippetsComponent;
	return snippets.determineSnippetInfo(document.uri.uriToFile, document.rawText, byteOff);
}

private void addDocComplete(ref CompletionItem[] completion, CompletionItem doc, string prefix)
in(!doc.insertText.isNone)
{
	if (!doc.label.startsWith(prefix))
		return;
	if (prefix.length > 0)
		doc.insertText = doc.insertText.deref[prefix.length .. $];
	completion ~= doc;
}

private bool isInComment(scope const(char)[] code, size_t at, WorkspaceD backend, Token* outToken = null)
{
	if (!backend)
		return false;

	import dparse.lexer : DLexer, LexerConfig, StringBehavior, tok;

	// TODO: does this kind of token parsing belong in serve-d?

	LexerConfig config;
	config.fileName = "stdin";
	config.stringBehavior = StringBehavior.source;
	auto lexer = DLexer(code, config, &backend.stringCache);

	while (!lexer.empty)
	{
		if (lexer.front.index > at)
			return false;

		switch (lexer.front.type)
		{
		case tok!"comment":
			auto t = lexer.front;

			auto commentEnd = t.index + t.text.length;
			if (t.text.startsWith("//"))
				commentEnd++;

			if (t.index <= at && at < commentEnd)
			{
				if (outToken !is null)
					*outToken = t;
				return true;
			}

			lexer.popFront();
			break;
		case tok!"__EOF__":
			if (outToken !is null)
				*outToken = lexer.front;
			return true;
		default:
			lexer.popFront();
			break;
		}
	}
	return false;
}

@protocolMethod("completionItem/resolve")
CompletionItem resolveCompletionItem(CompletionItem item)
{
	auto data = item.data;

	if (!data.isNone)
	{
		auto object = data.deref.get!(StringMap!JsonValue);
		const resolved = "resolved" in object;
		const uriObj = "uri" in object;
		const lineObj = "line" in object;
		const columnObj = "column" in object;

		if (uriObj && lineObj && columnObj)
		{
			auto uri = uriObj.get!string;
			auto line = cast(uint)lineObj.get!long;
			auto column = cast(uint)columnObj.get!long;

			Document document = documents[uri];
			auto f = document.uri.uriToFile;
			auto instance = backend.getBestInstance(f);

			if (resolved && !resolved.get!bool)
			{
				if (instance.has!SnippetsComponent)
				{
					auto snippets = instance.get!SnippetsComponent;
					auto snippet = snippetFromCompletionItem(item);
					snippet = snippets.resolveSnippet(f, document.rawText,
							cast(int) document.positionToBytes(Position(line, column)), snippet).getYield;
					item = snippetToCompletionItem(snippet);
				}
			}

			if (const importsJson = "imports" in object)
			{
				if (instance.has!ImporterComponent)
				{
					auto importer = instance.get!ImporterComponent;
					TextEdit[] additionalEdits = item.additionalTextEdits.orDefault;
					auto imports = importsJson.get!(JsonValue[]);
					foreach (importJson; imports)
					{
						string importName = importJson.get!string;
						auto importInfo = importer.add(importName, document.rawText,
								cast(int) document.positionToBytes(Position(line, column)));
						// TODO: use renamed imports properly
						foreach (edit; importInfo.replacements)
							additionalEdits ~= edit.toTextEdit(document);
					}
					additionalEdits.sort!"a.range.start>b.range.start";
					item.additionalTextEdits = additionalEdits;
				}
			}
		}

		if (const format = "format" in object)
		{
			auto args = format.get!string.split("\t");
			if (item.insertTextFormat.orDefault == InsertTextFormat.snippet)
			{
				SnippetLevel level = SnippetLevel.global;
				if (const levelStr = "level" in object)
					level = levelStr.get!string.to!SnippetLevel;
				item.insertText = formatSnippet(item.insertText.deref, args, level);
			}
			else
			{
				item.insertText = formatCode(item.insertText.deref, args);
			}
		}

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
	item.sortText = opt(sortPrefixSnippets ~ snippet.shortcut);
	item.detail = snippet.title;
	item.kind = CompletionItemKind.snippet;
	item.documentation = MarkupContent(MarkupKind.markdown,
			snippet.documentation ~ "\n\n```d\n" ~ snippet.snippet ~ "\n```\n");
	item.filterText = snippet.shortcut;
	if (capabilities
		.textDocument.orDefault
		.completion.orDefault
		.completionItem.orDefault
		.snippetSupport.orDefault)
	{
		item.insertText = snippet.snippet;
		item.insertTextFormat = InsertTextFormat.snippet;
	}
	else
		item.insertText = snippet.plain;

	item.data = JsonValue([
		"resolved": JsonValue(snippet.resolved),
		"id": JsonValue(snippet.id),
		"providerId": JsonValue(snippet.providerId),
		"data": snippet.data.toJsonValue
	]);
	return item;
}

Snippet snippetFromCompletionItem(CompletionItem item)
{
	Snippet snippet;
	snippet.shortcut = item.label;
	snippet.title = item.detail.deref;
	snippet.documentation = item.documentation.match!(
		() => cast(string)(null),
		(string s) => s,
		(MarkupContent c) => c.value
	);
	auto end = snippet.documentation.lastIndexOf("\n\n```d\n");
	if (end != -1)
		snippet.documentation = snippet.documentation[0 .. end];

	if (capabilities
		.textDocument.orDefault
		.completion.orDefault
		.completionItem.orDefault
		.snippetSupport.orDefault)
		snippet.snippet = item.insertText.deref;
	else
		snippet.plain = item.insertText.deref;

	auto itemData = item.data.deref.get!(StringMap!JsonValue);
	snippet.resolved = itemData["resolved"].get!bool;
	snippet.id = itemData["id"].get!string;
	snippet.providerId = itemData["providerId"].get!string;
	snippet.data = itemData["data"];
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

auto convertDCDIdentifiers(DCDIdentifier[] identifiers, bool argumentSnippets, DCDExtComponent dcdext,
	SnippetInfo info = SnippetInfo.init)
{
	CompletionItem[] completion;
	foreach (identifier; identifiers)
	{
		CompletionItem item;
		string detailDetail, detailDescription;
		item.label = identifier.identifier;
		item.kind = identifier.type.convertFromDCDType;
		if (identifier.documentation.length)
			item.documentation = MarkupContent(identifier.documentation.ddocToMarked);
		
		if (identifier.definition.length == 0)
		{
			if (identifier.type.length == 1)
			{
				switch (identifier.type[0])
				{
				case 'c':
					detailDescription = "Class";
					break;
				case 'i':
					detailDescription = "Interface";
					break;
				case 's':
					detailDescription = "Struct";
					break;
				case 'u':
					detailDescription = "Union";
					break;
				case 'a':
					detailDescription = "Array";
					break;
				case 'A':
					detailDescription = "AA";
					break;
				case 'v':
					detailDescription = "Variable";
					break;
				case 'm':
					detailDescription = "Member";
					break;
				case 'e':
					// lowercare to differentiate member from enum name
					detailDescription = "enum";
					break;
				case 'k':
					detailDescription = "Keyword";
					break;
				case 'f':
					detailDescription = "Function";
					break;
				case 'g':
					detailDescription = "Enum";
					break;
				case 'P':
					detailDescription = "Package";
					break;
				case 'M':
					detailDescription = "Module";
					break;
				case 't':
				case 'T':
					detailDescription = "Template";
					break;
				case 'h':
					detailDescription = "<T>";
					break;
				case 'p':
					detailDescription = "<T...>";
					break;
				case 'l': // Alias (eventually should show what it aliases to)
				default:
					break;
				}
			}
		}
		else
		{
			item.detail = identifier.definition;

			// check if that's actually a proper completion item to process
			auto definitionSpace = identifier.definition.indexOf(' ');
			if (definitionSpace != -1)
			{
				detailDescription = identifier.definition[0 .. definitionSpace];
				
				// if function or alias, only show the parenthesis content
				if (identifier.type == "f" || identifier.type == "l")
				{
					auto paren = identifier.definition.indexOf('(');
					if (paren != -1)
						detailDetail = " " ~ identifier.definition[paren .. $];
				}
			}

			if (identifier.typeOf.length && identifier.type != "f")
			{
				detailDescription = identifier.typeOf;
			}

			// handle special cases
			if (identifier.type == "e")
			{
				// enum definitions are the enum identifiers (not the type)
				detailDescription = "enum";
			}
			else if ((identifier.type == "f" || (identifier.type == "l" || identifier.definition.indexOf(" ") != -1)) && dcdext)
			{
				CalltipsSupport funcParams = dcdext.extractCallParameters(
					identifier.definition, cast(int) identifier.definition.length - 1, true);

				// if definition doesn't contains a return type, then it is a function that returns auto
				// it could be 'enum', but that's typically the same, and there is no way to get that info right now
				// need to check on DCD's part, auto/enum are removed from the definition
				auto nameEnd = funcParams.templateArgumentsRange[0];
				if (!nameEnd) nameEnd = funcParams.functionParensRange[0];
				if (!nameEnd) nameEnd = cast(int) identifier.definition.length;
				auto retTypeEnd = identifier.definition.lastIndexOf(' ', nameEnd);
				if (retTypeEnd != -1)
					detailDescription = identifier.definition[0 .. retTypeEnd].strip;
				else
					detailDescription = "auto";

				detailDetail = " " ~ identifier.definition[nameEnd .. $];
			}

			item.sortText = identifier.identifier ~ " " ~ identifier.definition;

			// TODO: only add arguments when this is a function call, eg not on template arguments
			if (identifier.type == "f" && argumentSnippets
				&& info.level.among!(SnippetLevel.method, SnippetLevel.value))
			{
				item.insertTextFormat = InsertTextFormat.snippet;
				string args;
				auto parts = identifier.definition.extractFunctionParameters(true, dcdext);
				trace("snippet method complete: ", identifier.definition, " -> ", parts);
				foreach (i, part; parts.functionArgs)
				{
					auto name = identifier.definition[part.nameRange[0] .. part.nameRange[1]];

					if (args.length)
						args ~= ", ";
					args ~= "${" ~ (i + 1).to!string ~ ":" ~ name ~ "}";
				}
				item.insertText = identifier.identifier ~ "(${0:" ~ args ~ "})";
			}
		}

		if (item.sortText.isNone)
			item.sortText = item.label;

		item.sortText = sortPrefixDCD ~ identifier.type.sortFromDCDType ~ item.sortText.deref;

		if (detailDescription.length || detailDetail.length)
		{
			CompletionItemLabelDetails d;
			if (detailDetail.length)
				d.detail = detailDetail;
			if (detailDescription.length)
				d.description = detailDescription;

			item.labelDetails = d;
		}

		completion ~= item;
	}

	// sort only for duplicate detection (use sortText for UI sorting)
	completion.sort!"a.effectiveInsertText < b.effectiveInsertText";
	return completion.chunkBy!(
			(a, b) =>
				a.effectiveInsertText == b.effectiveInsertText
				&& a.kind == b.kind
		).map!((a) {
			CompletionItem ret = a.front;
			auto details = a.map!"a.detail"
				.filter!(a => !a.isNone && a.deref.length)
				.uniq
				.array;
			auto docs = a.map!"a.documentation"
				.filter!(a => a.match!(
					() => false,
					(string s) => s.length > 0,
					(MarkupContent s) => s.value.length > 0,
				))
				.uniq
				.array;
			auto labelDetails = a.map!"a.labelDetails"
				.filter!(a => !a.isNone)
				.uniq
				.array;
			if (docs.length)
				ret.documentation = MarkupContent(MarkupKind.markdown,
					docs.map!(a => a.match!(
						() => assert(false),
						(string s) => s,
						(MarkupContent s) => s.value,
					)).join("\n\n"));
			if (details.length)
				ret.detail = details.map!(a => a.deref).join("\n");

			if (labelDetails.length == 1)
			{
				ret.labelDetails = labelDetails[0];
			}
			else if (labelDetails.length > 1)
			{
				auto descriptions = labelDetails
					.filter!(a => !a.deref.description.isNone)
					.map!(a => a.deref.description.deref)
					.array
					.sort!"a<b"
					.uniq
					.array;
				auto detailDetails = labelDetails
					.filter!(a => !a.deref.detail.isNone)
					.map!(a => a.deref.detail.deref)
					.array
					.sort!"a<b"
					.uniq
					.array;

				CompletionItemLabelDetails detail;
				if (descriptions.length == 1)
					detail.description = descriptions[0];
				else if (descriptions.length)
					detail.description = descriptions.join(" | ");

				if (detailDetails.length == 1)
					detail.detail = detailDetails[0];
				else if (detailDetails.length && detailDetails[0].endsWith(")"))
					detail.detail = format!" (*%d overloads*)"(detailDetails.length);
				else if (detailDetails.length) // dunno when/if this can even happen
					detail.description = detailDetails.join(" |");

				ret.labelDetails = detail;
			}

			migrateLabelDetailsSupport(ret);
			return ret;
		})
		.array;
}

private void migrateLabelDetailsSupport(ref CompletionItem item)
{
	if (!capabilities
		.textDocument.orDefault
		.completion.orDefault
		.completionItem.orDefault
		.labelDetailsSupport.orDefault
		&& !item.labelDetails.isNone)
	{
		// labelDetails is not supported, but let's use what we computed, it's
		// still very useful
		CompletionItemLabelDetails detail = item.labelDetails.deref;

		// don't overwrite `detail`, it may be used to show full definition in a
		// documentation popup.

		// if we got a detailed detail, use that and properly set the insertText
		if (!detail.detail.isNone)
		{
			if (item.insertText.isNone)
				item.insertText = item.label;
			item.label ~= detail.detail.deref;
		}

		item.labelDetails = item.labelDetails._void;
	}
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
