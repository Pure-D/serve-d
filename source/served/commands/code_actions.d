module served.commands.code_actions;

import served.extension;
import served.types;
import served.utils.fibermanager;

import workspaced.api;
import workspaced.com.dcdext;
import workspaced.com.importer;
import workspaced.coms;

import served.commands.format : generateDfmtArgs;

import served.linters.dscanner : DScannerDiagnosticSource;
import served.linters.dub : DubDiagnosticSource;

import std.algorithm : canFind, map, min, sort, startsWith, uniq;
import std.array : array;
import std.conv : to;
import std.experimental.logger;
import std.json : JSONType, JSONValue;
import std.path : buildNormalizedPath, isAbsolute;
import std.regex : matchFirst, regex, replaceAll;
import std.string : indexOf, indexOfAny, join, replace, strip;

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
Command[] provideCodeActions(CodeActionParams params)
{
	auto document = documents[params.textDocument.uri];
	auto instance = activeInstance = backend.getBestInstance(document.uri.uriToFile);
	if (document.languageId != "d" || !instance)
		return [];
	Command[] ret;
	if (instance.has!DCDExtComponent) // check if extends
	{
		scope codeText = document.rawText.idup;
		auto startIndex = document.positionToBytes(params.range.start);
		ptrdiff_t idx = min(cast(ptrdiff_t) startIndex, cast(ptrdiff_t) codeText.length - 1);
		while (idx > 0)
		{
			if (codeText[idx] == ':')
			{
				// probably extends
				if (instance.get!DCDExtComponent.implementAll(codeText,
						cast(int) startIndex).getYield.length > 0)
					ret ~= Command("Implement base classes/interfaces", "code-d.implementMethods",
							[JSONValue(document.positionToOffset(params.range.start))]);
				break;
			}
			if (codeText[idx] == ';' || codeText[idx] == '{' || codeText[idx] == '}')
				break;
			idx--;
		}
	}
	foreach (diagnostic; params.context.diagnostics)
	{
		if (diagnostic.source == DubDiagnosticSource)
		{
			auto match = diagnostic.message.matchFirst(importRegex);
			if (diagnostic.message.canFind("import ") && match)
			{
				ret ~= Command("Import " ~ match[1], "code-d.addImport",
						[
							JSONValue(match[1]),
							JSONValue(document.positionToOffset(params.range[0]))
						]);
			}
			if (cast(bool)(match = diagnostic.message.matchFirst(undefinedIdentifier))
					|| cast(bool)(match = diagnostic.message.matchFirst(undefinedTemplate))
					|| cast(bool)(match = diagnostic.message.matchFirst(noProperty)))
			{
				string[] files;
				string[] modules;
				int lineNo;
				joinAll({
					files ~= instance.get!DscannerComponent.findSymbol(match[1])
						.getYield.map!"a.file".array;
				}, {
					if (instance.has!DCDComponent)
						files ~= instance.get!DCDComponent.searchSymbol(match[1]).getYield.map!"a.file".array;
				} /*, {
					struct Symbol
					{
						string project, package_;
					}

					StopWatch sw;
					bool got;
					Symbol[] symbols;
					sw.start();
					info("asking the interwebs for ", match[1]);
					new Thread({
						import std.net.curl : get;
						import std.uri : encodeComponent;

						auto str = get(
						"https://symbols.webfreak.org/symbols?limit=60&identifier=" ~ encodeComponent(match[1]));
						foreach (symbol; parseJSON(str).array)
							symbols ~= Symbol(symbol["project"].str, symbol["package"].str);
						got = true;
					}).start();
					while (sw.peek < 3.seconds && !got)
						Fiber.yield();
					foreach (v; symbols.sort!"a.project < b.project"
						.uniq!"a.project == b.project")
						ret ~= Command("Import " ~ v.package_ ~ " from dub package " ~ v.project);
				}*/
				);
				info("Files: ", files);
				foreach (file; files.sort().uniq)
				{
					if (!isAbsolute(file))
						file = buildNormalizedPath(instance.cwd, file);
					if (!fs.exists(file))
						continue;
					lineNo = 0;
					foreach (line; io.File(file).byLine)
					{
						if (++lineNo >= 100)
							break;
						auto match2 = line.matchFirst(moduleRegex);
						if (match2)
						{
							modules ~= match2[1].replaceAll(whitespace, "").idup;
							break;
						}
					}
				}
				foreach (mod; modules.sort().uniq)
					ret ~= Command("Import " ~ mod, "code-d.addImport", [
							JSONValue(mod),
							JSONValue(document.positionToOffset(params.range[0]))
							]);
			}
		}
		else if (diagnostic.source == DScannerDiagnosticSource)
		{
			import dscanner.analysis.imports_sortedness : ImportSortednessCheck;

			string key = diagnostic.code.type == JSONType.string ? diagnostic.code.str : null;

			info("Diagnostic: ", diagnostic);

			if (key == ImportSortednessCheck.KEY)
			{
				ret ~= Command("Sort imports", "code-d.sortImports",
						[JSONValue(document.positionToOffset(params.range[0]))]);
			}

			if (key.length)
			{
				if (key.startsWith("dscanner."))
					key = key["dscanner.".length .. $];
				ret ~= Command("Ignore " ~ key ~ " warnings", "code-d.ignoreDscannerKey", [
						diagnostic.code
						]);
				ret ~= Command("Ignore " ~ key ~ " warnings (this line)",
						"code-d.ignoreDscannerKey", [diagnostic.code, JSONValue("line")]);
			}
		}
	}
	return ret;
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
	auto end = document.bytesToPosition(sorted.end);
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
			config.d.enableFormatting, generateDfmtArgs(config, eol), implementInterfaceSnippets)
		.getYield;
	if (!toImplement.length)
		return ret;

	string formatCode(ImplementedMethod method)
	{
		// cool! snippets handle indentation and new lines automatically so we just keep it as is
		return method.code;
	}

	auto existing = backend.best!DCDExtComponent(file).getInterfaceDetails(file,
			codeText, cast(int) location);
	if (existing == InterfaceDetails.init)
	{
		// insert at start (could not parse class properly)
		auto brace = codeText.indexOf('{', location);
		if (brace == -1)
			brace = codeText.length;
		brace++;
		auto pos = document.bytesToPosition(brace);
		return [
			TextEdit(TextRange(pos, pos),
					eolStr ~ eolStr ~ toImplement.map!(a => formatCode(a)).join(eolStr ~ eolStr))
		];
	}
	else if (existing.methods.length == 0)
	{
		// insert at end (no methods in class)
		auto end = document.bytesToPosition(existing.blockRange[1] - 1);
		return [
			TextEdit(TextRange(end, end), eolStr ~ toImplement.map!(a => formatCode(a))
					.join(eolStr ~ eolStr) ~ eolStr)
		];
	}
	else
	{
		// simply insert at the end of methods, maybe we want to add sorting?
		// ... ofc that would need a configuration flag because once this is in for a while at least one user will have get used to this and wants to continue having it.
		auto end = document.bytesToPosition(existing.methods[$ - 1].blockRange[1]);
		return [
			TextEdit(TextRange(end, end),
					eolStr ~ eolStr ~ toImplement.map!(a => formatCode(a)).join(eolStr ~ eolStr) ~ eolStr)
		];
	}
}
