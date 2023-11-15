module served.commands.code_actions;

import served.extension;
import served.types;
import served.utils.fibermanager;

import workspaced.api;
import workspaced.com.dcdext;
import workspaced.com.importer;
import workspaced.com.index;
import workspaced.coms;

import served.commands.format : generateDfmtArgs;

import served.linters.dscanner : DScannerDiagnosticSource, SyntaxHintDiagnosticSource;
import served.linters.dub : DubDiagnosticSource;

import std.algorithm : canFind, endsWith, find, findSplit, map, min, sort, startsWith, uniq;
import std.array : array;
import std.conv : to;
import std.experimental.logger;
import std.format : format;
import std.path : buildNormalizedPath, isAbsolute;
import std.regex : Captures, matchFirst, regex, replaceAll;
import std.string : chomp, indexOf, indexOfAny, join, replace, strip;

import fs = std.file;
import io = std.stdio;

package auto importRegex = regex(`import\s+(?:[a-zA-Z_]+\s*=\s*)?([a-zA-Z_]\w*(?:\.\w*[a-zA-Z_]\w*)*)?(\s*\:\s*(?:[a-zA-Z_,\s=]*(?://.*?[\r\n]|/\*.*?\*/|/\+.*?\+/)?)+)?;?`);
package static immutable regexQuoteChars = "['\"`]?";
package auto undefinedIdentifier = regex(`^undefined identifier ` ~ regexQuoteChars ~ `(\w+)`
		~ regexQuoteChars ~ `(?:, did you mean .*? ` ~ regexQuoteChars ~ `(\w+)`
		~ regexQuoteChars ~ `\?)?$`);
package auto undefinedTemplate = regex(
		`template ` ~ regexQuoteChars ~ `(\w+)` ~ regexQuoteChars ~ ` is not defined`);
package auto noProperty = regex(`^no property ` ~ regexQuoteChars ~ `(\w+)`
		~ regexQuoteChars ~ `(?: for type ` ~ regexQuoteChars ~ `.*?` ~ regexQuoteChars ~ `)?$`);
package auto moduleRegex = regex(
		`(?<!//.*)\bmodule\s+([a-zA-Z_]\w*\s*(?:\s*\.\s*[a-zA-Z_]\w*)*)\s*;`);
package auto whitespace = regex(`\s*`);

@protocolMethod("textDocument/codeAction")
CodeAction[] provideCodeActions(CodeActionParams params)
{
	auto document = documents[params.textDocument.uri];
	auto instance = activeInstance = backend.getBestInstance(document.uri.uriToFile);
	if (document.getLanguageId != "d" || !instance)
		return [];
	auto config = workspace(params.textDocument.uri).config;

	// eagerly load DCD in opened files which request code actions
	if (instance.has!DCDComponent)
		instance.get!DCDComponent();

	auto startBytes = document.positionToBytes(params.range.start);

	CodeAction[] ret;
	if (instance.has!DCDExtComponent) // check if extends
	{
		scope codeText = document.rawText.idup;
		ptrdiff_t idx = min(cast(ptrdiff_t) startBytes, cast(ptrdiff_t) codeText.length - 1);
		while (idx > 0)
		{
			if (codeText[idx] == ':')
			{
				// probably extends
				if (instance.get!DCDExtComponent.implementAll(codeText, cast(int) startBytes).length > 0)
				{
					Command cmd = {
						title: "Implement base classes/interfaces",
						command: "code-d.implementMethods",
						arguments: [
							JsonValue(document.positionToOffset(params.range.start))
						]
					};
					ret ~= CodeAction(cmd);
				}
				break;
			}
			if (codeText[idx] == ';' || codeText[idx] == '{' || codeText[idx] == '}')
				break;
			idx--;
		}
	}

	addDubDiagnostics(ret, instance, document, params, startBytes);
	foreach (diagnostic; params.context.diagnostics)
	{
		if (diagnostic.source == DScannerDiagnosticSource)
		{
			addDScannerDiagnostics(config, ret, instance, document, diagnostic, params);
		}
		else if (diagnostic.source == SyntaxHintDiagnosticSource)
		{
			addSyntaxDiagnostics(ret, instance, document, diagnostic, params);
		}
	}
	return ret;
}

void addDubDiagnostics(ref CodeAction[] ret, WorkspaceD.Instance instance,
	Document document, CodeActionParams params, size_t rangeStartBytes)
{
	auto diagnostics = params.context.diagnostics;

	if (instance.has!IndexComponent)
	{
		size_t[2][] undefinedIndices;
		string[] undefinedIdentifiers;
		Captures!string match;
		foreach (diagnostic; diagnostics)
		{
			if (cast(bool)(match = diagnostic.message.matchFirst(undefinedIdentifier))
					|| cast(bool)(match = diagnostic.message.matchFirst(undefinedTemplate))
					|| cast(bool)(match = diagnostic.message.matchFirst(noProperty)))
			{
				undefinedIndices ~= document.textRangeToByteRange(diagnostic.range);
				undefinedIdentifiers ~= match[1];
				break;
			}
		}

		if (!undefinedIdentifiers.length)
		{
			auto startRange = document.wordRangeAt(rangeStartBytes);
			if (params.range.start != params.range.end)
				startRange = document.textRangeToByteRange(params.range);
			auto identifier = document.sliceRawText(startRange);

			if (isValidDIdentifier(identifier))
			{
				undefinedIndices ~= startRange;
				undefinedIdentifiers ~= identifier.idup;
			}
		}

		// assumptions:
		// if [1] is non-empty, then [0] is used just for sorting
		// if [1] is empty, [0] is assumed to be the file path to read the module from
		string[2][] importModuleSuggestsions;
		foreach (i, identifier; undefinedIdentifiers)
		{
			auto range = undefinedIndices[i];
			CompletionItem[] availableSymbols;
			provideAutoImports(TextDocumentPositionParams.init, instance,
				document, availableSymbols, cast(int)range[0], identifier, true);

			foreach (sym; availableSymbols)
			{
				if (!sym.insertText.isNone)
				{
					string replacement = sym.insertText.deref;
					TextEditCollection[DocumentUri] changes;
					changes[document.uri] = [
						TextEdit(document.byteRangeToTextRange(range), replacement)
					];
					ret ~= CodeAction("Change to `" ~ replacement ~ "`", WorkspaceEdit(changes));
				}
				else
				{
					auto data = sym.data.deref.get!(StringMap!JsonValue);
					string[2] sortAndMod;
					sortAndMod[0] = sym.sortText.deref;
					sortAndMod[1] = data["moduleName"].get!string;
					importModuleSuggestsions ~= sortAndMod;
				}
			}
		}
		importModuleSuggestsions.sort();
		foreach (mod; importModuleSuggestsions.map!"a[1]".uniq)
			if (mod.length)
				ret ~= CodeAction(Command("Import " ~ mod, "code-d.addImport", [
					JsonValue(mod),
					JsonValue(document.positionToOffset(params.range[0]))
				]));
	}
	else
	{
		foreach (diagnostic; diagnostics)
		{
			auto match = diagnostic.message.matchFirst(importRegex);
			if (diagnostic.message.canFind("import ") && match)
			{
				ret ~= CodeAction(Command("Import " ~ match[1], "code-d.addImport",
					[
						JsonValue(match[1]),
						JsonValue(document.positionToOffset(diagnostic.range.start))
					]));
			}
		}
	}

	void autofixFromError(T)(Diagnostic diag, T check)
	{
		static if (is(T : Diagnostic))
			auto range = check.range;
		else
		{
			if (check.location.uri != document.uri)
				return;

			auto range = check.location.range;
		}

		if (check.message.startsWith("use `is` instead of `==`",
				"use `!is` instead of `!=`")
			&& range.end.character - range.start.character == 2)
		{
			auto b = document.positionToBytes(range.start);
			auto text = document.rawText[b .. $];

			string target = check.message[5] == '!' ? "!=" : "==";
			string replacement = check.message[5] == '!' ? "!is" : "is";

			if (text.startsWith(target))
			{
				string title = format!"Change '%s' to '%s'"(target, replacement);
				TextEditCollection[DocumentUri] changes;
				changes[document.uri] = [TextEdit(range, replacement)];
				auto action = CodeAction(title, WorkspaceEdit(changes));
				action.isPreferred = true;
				action.diagnostics = [diag];
				action.kind = CodeActionKind.quickfix;
				ret ~= action;
			}
		}
		else if (check.message.startsWith("perhaps change the `"))
		{
			auto line = check.message["perhaps change the `".length .. $].strip;
			auto parts = line.findSplit("` into `");
			if (parts[2].endsWith("`"))
			{
				auto action = createCodeReplacementSuggestion(ret, document, parts[0], parts[2].chomp("`"), range.start);
				if (action != CodeAction.init)
				{
					action.diagnostics = [diag];
					action.isPreferred = true;
					ret ~= action;
				}
			}
		}
	}

	foreach (diagnostic; diagnostics)
	{
		autofixFromError(diagnostic, diagnostic);
		if (!diagnostic.relatedInformation.isNone)
			foreach (related; diagnostic.relatedInformation.deref)
				autofixFromError(diagnostic, related);
	}
}

private CodeAction createCodeReplacementSuggestion(ref CodeAction[] ret,
	Document document, scope const(char)[] from, scope const(char)[] to, Position at)
{
	import dparse.lexer;
	import workspaced.dparseext : textLength;

	StringCache stringCache = StringCache(StringCache.defaultBucketCount);

	auto lineRange = document.lineByteRangeAt(at.line);
	auto line = document.rawText[lineRange[0] .. lineRange[1]];
	auto lineTokens = getTokensForParser(line, LexerConfig.init, &stringCache);
	auto fromTokens = getTokensForParser(from, LexerConfig.init, &stringCache);

	ptrdiff_t startIndex = -1;
	ptrdiff_t endIndex = -1;
	auto start = lineTokens.find(fromTokens);
	if (!start.length)
		return CodeAction.init;
	assert(start.length >= fromTokens.length);

	foreach (i; 0 .. fromTokens.length)
	{
		if (startIndex == -1)
			startIndex = start[0].index;
		endIndex = start[0].index + start[0].textLength;
		start = start[1 .. $];
	}

	Position cachePos;
	size_t cacheIdx;

	startIndex += lineRange[0];
	endIndex += lineRange[0];

	TextRange range;
	range.start = document.movePositionBytes(cachePos, cacheIdx, startIndex);
	range.end = document.movePositionBytes(cachePos, cacheIdx, endIndex);

	string title = format!"Change '%s' to '%s'"(from, to);
	TextEditCollection[DocumentUri] changes;
	changes[document.uri] = [TextEdit(range, to.idup)];
	auto action = CodeAction(title, WorkspaceEdit(changes));
	action.kind = CodeActionKind.quickfix;
	return action;
}

void addDScannerDiagnostics(const ref UserConfiguration config,
	ref CodeAction[] ret, WorkspaceD.Instance instance,
	Document document, Diagnostic diagnostic, CodeActionParams params)
{
	import dscanner.analysis.imports_sortedness : ImportSortednessCheck;
	import served.linters.dscanner : diagnosticDataToCodeReplacement,
		diagnosticDataToResolveContext, servedDefaultDscannerConfig;
	import workspaced.com.dscanner : DScannerAutoFix;

	Position cachePos;
	size_t cacheIndex;

	TextEdit toTextEdit(DScannerAutoFix.CodeReplacement replacement)
	{
		return TextEdit(
			TextRange(
				document.nextPositionBytes(cachePos, cacheIndex, replacement.range[0]),
				document.nextPositionBytes(cachePos, cacheIndex, replacement.range[1])
			),
			replacement.newText
		);
	}

	string key = diagnostic.code.orDefault.match!((string s) => s, _ => cast(string)(null));

	if (key == ImportSortednessCheck.KEY)
	{
		ret ~= CodeAction(Command("Sort imports", "code-d.sortImports",
				[JsonValue(document.positionToOffset(params.range[0]))]));
	}

	if (!diagnostic.data.isNone)
	{
		auto data = diagnostic.data.deref;
		if (auto autofixes = "autofixes" in data.object)
		{
			string checkName = data.object["checkName"].string;

			DScannerAutoFix.ResolveContext[] resolveContexts;
			size_t[] resolveContextIndices;

			foreach (autofix; autofixes.array)
			{
				if (autofix.kind != JsonValue.Kind.object)
				{
					warning("Unsupported dscanner autofix: ", autofix);
					continue;
				}

				auto nameJson = "name" in autofix.object;
				if (!nameJson)
				{
					warning("Unsupported dscanner autofix: ", autofix);
					continue;
				}
				string name = (*nameJson).get!string;

				DScannerAutoFix.CodeReplacement[] codeReplacements;

				if (auto replacements = "replacements" in autofix.object)
				{
					codeReplacements = (*replacements).array.map!(
						j => diagnosticDataToCodeReplacement(j)
					).array;
				}
				else if (auto jcontext = "context" in autofix.object)
				{
					resolveContexts ~= diagnosticDataToResolveContext(*jcontext);
					resolveContextIndices ~= ret.length;
				}
				else
				{
					warning("Unsupported dscanner autofix: ", autofix);
					continue;
				}

				ret ~= CodeAction(name, WorkspaceEdit([
					document.uri: codeReplacements.map!toTextEdit.array
				]));
			}

			if (resolveContexts.length)
			{
				auto codeReplacementsList = instance.get!DscannerComponent.resolveAutoFixes(
					checkName, resolveContexts, document.uri.uriToFile, "dscanner.ini",
					generateDfmtArgs(config, document.eolAt(0)), document.rawText, false,
					servedDefaultDscannerConfig);

				foreach (i, codeReplacements; codeReplacementsList)
				{
					ret[resolveContextIndices[i]].edit = WorkspaceEdit([
						document.uri: codeReplacements.map!toTextEdit.array
					]);
				}
			}
		}
	}

	if (key.length)
	{
		JsonValue code = diagnostic.code.match!(() => JsonValue(null), j => j);
		if (key.startsWith("dscanner."))
			key = key["dscanner.".length .. $];
		ret ~= CodeAction(Command("Ignore " ~ key ~ " warnings (this line)",
			"code-d.ignoreDscannerKey", [code, JsonValue("line")]));
		ret ~= CodeAction(Command("Ignore " ~ key ~ " warnings",
			"code-d.ignoreDscannerKey", [code]));
	}
}

void addSyntaxDiagnostics(ref CodeAction[] ret, WorkspaceD.Instance instance,
	Document document, Diagnostic diagnostic, CodeActionParams params)
{
	string key = diagnostic.code.orDefault.match!((string s) => s, _ => cast(string)(null));
	switch (key)
	{
	case "workspaced.foreach-auto":
		auto b = document.positionToBytes(diagnostic.range.start);
		auto text = document.rawText[b .. $];

		if (text.startsWith("auto"))
		{
			auto range = diagnostic.range;
			size_t offset = 4;
			foreach (i, dchar c; text[4 .. $])
			{
				offset = 4 + i;
				if (!isDIdentifierSeparatingChar(c))
					break;
			}
			range.end = range.start;
			range.end.character += offset;
			string title = "Remove 'auto' to fix syntax";
			TextEditCollection[DocumentUri] changes;
			changes[document.uri] = [TextEdit(range, "")];
			auto action = CodeAction(title, WorkspaceEdit(changes));
			action.isPreferred = true;
			action.diagnostics = [diagnostic];
			action.kind = CodeActionKind.quickfix;
			ret ~= action;
		}
		break;
	default:
		warning("No diagnostic fix for our own diagnostic: ", diagnostic);
		break;
	}
}

/// Command to sort all user imports in a block at a given position in given code. Returns a list of changes to apply. (Replaces the whole block currently if anything changed, otherwise empty)
@protocolMethod("served/sortImports")
TextEdit[] sortImports(SortImportsParams params)
{
	auto document = documents[params.textDocument.uri];
	TextEdit[] ret;
	auto sorted = backend.get!ImporterComponent.sortImports(document.rawText,
			cast(int) document.offsetToBytes(params.location));
	if (sorted == ImportBlock.init)
		return ret;
	auto start = document.bytesToPosition(sorted.start);
	auto end = document.movePositionBytes(start, sorted.start, sorted.end);
	auto lines = sorted.imports.to!(string[]);
	if (!lines.length)
		return null;
	foreach (ref line; lines[1 .. $])
		line = sorted.indentation ~ line;
	string code = lines.join(document.eolAt(0).toString);
	return [TextEdit(TextRange(start, end), code)];
}

/// Flag to make dcdext.implementAll return snippets
__gshared bool implementInterfaceSnippets;

/// Implements the interfaces or abstract classes of a specified class/interface. The given position must be on/inside the identifier of any subclass after the colon (`:`) in a class definition.
@protocolMethod("served/implementMethods")
TextEdit[] implementMethods(ImplementMethodsParams params)
{
	import std.ascii : isWhite;

	auto document = documents[params.textDocument.uri];
	string file = document.uri.uriToFile;
	auto config = workspace(params.textDocument.uri).config;
	TextEdit[] ret;
	auto location = document.offsetToBytes(params.location);
	scope codeText = document.rawText.idup;

	if (gFormattingOptionsApplyOn != params.textDocument.uri)
		tryFindFormattingSettings(config, document);

	auto eol = document.eolAt(0);
	auto eolStr = eol.toString;
	auto toImplement = backend.best!DCDExtComponent(file).implementAll(codeText, cast(int) location,
			config.d.enableFormatting, generateDfmtArgs(config, eol), implementInterfaceSnippets);
	if (!toImplement.length)
		return ret;

	string formatCode(ImplementedMethod method, bool needsIndent = false)
	{
		if (needsIndent)
		{
			// start/end of block where it's not intended
			return "\t" ~ method.code.replace("\n", "\n\t");
		}
		else
		{
			// cool! snippets handle indentation and new lines automatically so we just keep it as is
			return method.code;
		}
	}

	auto existing = backend.best!DCDExtComponent(file).getInterfaceDetails(file,
			codeText, cast(int) location);
	if (existing == InterfaceDetails.init || existing.isEmpty)
	{
		// insert at start (could not parse class properly or class is empty)
		auto brace = codeText.indexOf('{', location);
		if (brace == -1)
			brace = codeText.length;
		brace++;
		auto pos = document.bytesToPosition(brace);
		return [
			TextEdit(TextRange(pos, pos),
					eolStr
					~ toImplement
						.map!(a => formatCode(a, true))
						.join(eolStr ~ eolStr))
		];
	}
	else if (existing.methods.length == 0)
	{
		// insert at end (no methods in class)
		auto end = document.bytesToPosition(existing.blockRange[1] - 1);
		return [
			TextEdit(TextRange(end, end),
				eolStr
				~ toImplement
					.map!(a => formatCode(a, true))
					.join(eolStr ~ eolStr)
				~ eolStr)
		];
	}
	else
	{
		// simply insert at the end of methods, maybe we want to add sorting?
		// ... ofc that would need a configuration flag because once this is in for a while at least one user will have get used to this and wants to continue having it.
		auto end = document.bytesToPosition(existing.methods[$ - 1].blockRange[1]);
		return [
			TextEdit(TextRange(end, end),
					eolStr
					~ eolStr
					~ toImplement
						.map!(a => formatCode(a, false))
						.join(eolStr ~ eolStr)
					~ eolStr)
		];
	}
}
