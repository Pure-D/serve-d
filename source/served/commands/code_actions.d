module served.commands.code_actions;

import served.extension;
import served.fibermanager;
import served.types;

import workspaced.api;
import workspaced.com.importer;
import workspaced.coms;

import served.linters.dub : DubDiagnosticSource;
import served.linters.dscanner : DScannerDiagnosticSource;

import std.array : array;
import std.conv : to;
import std.regex : regex, matchFirst, replaceAll;
import std.algorithm : min, canFind, sort, startsWith, uniq, map;
import std.path : isAbsolute, buildNormalizedPath;
import std.experimental.logger;
import std.string : strip, indexOf, replace, join, indexOfAny;
import std.json : JSONValue, JSON_TYPE;

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
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	Command[] ret;
	if (backend.has!DCDExtComponent(workspaceRoot)) // check if extends
	{
		auto startIndex = document.positionToBytes(params.range.start);
		ptrdiff_t idx = min(cast(ptrdiff_t) startIndex, cast(ptrdiff_t) document.text.length - 1);
		while (idx > 0)
		{
			if (document.text[idx] == ':')
			{
				// probably extends
				if (backend.get!DCDExtComponent(workspaceRoot)
						.implement(document.text, cast(int) startIndex).getYield.strip.length > 0)
					ret ~= Command("Implement base classes/interfaces", "code-d.implementMethods",
							[JSONValue(document.positionToOffset(params.range.start))]);
				break;
			}
			if (document.text[idx] == ';' || document.text[idx] == '{' || document.text[idx] == '}')
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
						[JSONValue(match[1]), JSONValue(document.positionToOffset(params.range[0]))]);
			}
			if (cast(bool)(match = diagnostic.message.matchFirst(undefinedIdentifier))
					|| cast(bool)(match = diagnostic.message.matchFirst(undefinedTemplate))
					|| cast(bool)(match = diagnostic.message.matchFirst(noProperty)))
			{
				string[] files;
				string[] modules;
				int lineNo;
				joinAll({
					files ~= backend.get!DscannerComponent(workspaceRoot)
						.findSymbol(match[1]).getYield.map!"a.file".array;
				}, {
					if (backend.has!DCDComponent(workspaceRoot))
						files ~= backend.get!DCDComponent(workspaceRoot)
							.searchSymbol(match[1]).getYield.map!"a.file".array;
				}/*, {
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
				}*/);
				info("Files: ", files);
				foreach (file; files.sort().uniq)
				{
					if (!isAbsolute(file))
						file = buildNormalizedPath(workspaceRoot, file);
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
					ret ~= Command("Import " ~ mod, "code-d.addImport", [JSONValue(mod),
							JSONValue(document.positionToOffset(params.range[0]))]);
			}
		}
		else if (diagnostic.source == DScannerDiagnosticSource)
		{
			import dscanner.analysis.imports_sortedness : ImportSortednessCheck;

			string key = diagnostic.code.type == JSON_TYPE.STRING ? diagnostic.code.str : null;

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
				ret ~= Command("Ignore " ~ key ~ " warnings", "code-d.ignoreDscannerKey", [diagnostic.code]);
				ret ~= Command("Ignore " ~ key ~ " warnings (this line)",
						"code-d.ignoreDscannerKey", [diagnostic.code, JSONValue("line")]);
			}
		}
	}
	return ret;
}

@protocolMethod("served/sortImports")
TextEdit[] sortImports(SortImportsParams params)
{
	auto document = documents[params.textDocument.uri];
	TextEdit[] ret;
	auto sorted = backend.get!ImporterComponent.sortImports(document.text,
			cast(int) document.offsetToBytes(params.location));
	if (sorted == ImportBlock.init)
		return ret;
	auto start = document.bytesToPosition(sorted.start);
	auto end = document.bytesToPosition(sorted.end);
	string code = sorted.imports.to!(string[]).join(document.eolAt(0).toString);
	return [TextEdit(TextRange(start, end), code)];
}

@protocolMethod("served/implementMethods")
TextEdit[] implementMethods(ImplementMethodsParams params)
{
	import std.ascii : isWhite;

	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	TextEdit[] ret;
	auto location = document.offsetToBytes(params.location);
	auto code = backend.get!DCDExtComponent(workspaceRoot)
		.implement(document.text, cast(int) location).getYield.strip;
	if (!code.length)
		return ret;
	auto brace = document.text.indexOf('{', location);
	auto fallback = brace;
	if (brace == -1)
		brace = document.text.length;
	else
	{
		fallback = document.text.indexOf('\n', location);
		brace = document.text.indexOfAny("}\n", brace);
		if (brace == -1)
			brace = document.text.length;
	}
	code = "\n\t" ~ code.replace("\n", document.eolAt(0).toString ~ "\t") ~ "\n";
	bool inIdentifier = true;
	int depth = 0;
	foreach (i; location .. brace)
	{
		if (document.text[i].isWhite)
			inIdentifier = false;
		else if (document.text[i] == '{')
			break;
		else if (document.text[i] == ',' || document.text[i] == '!')
			inIdentifier = true;
		else if (document.text[i] == '(')
			depth++;
		else
		{
			if (depth > 0)
			{
				inIdentifier = true;
				if (document.text[i] == ')')
					depth--;
			}
			else if (!inIdentifier)
			{
				if (fallback != -1)
					brace = fallback;
				code = "\n{" ~ code ~ "}";
				break;
			}
		}
	}
	auto pos = document.bytesToPosition(brace);
	return [TextEdit(TextRange(pos, pos), code)];
}