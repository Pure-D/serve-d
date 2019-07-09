module served.commands.code_actions;

import served.extension;
import served.fibermanager;
import served.types;

import workspaced.api;
import workspaced.com.importer;
import workspaced.coms;

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
				if (instance.get!DCDExtComponent.implement(codeText,
						cast(int) startIndex).getYield.strip.length > 0)
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

@protocolMethod("served/implementMethods")
TextEdit[] implementMethods(ImplementMethodsParams params)
{
	import std.ascii : isWhite;

	auto document = documents[params.textDocument.uri];
	string file = document.uri.uriToFile;
	TextEdit[] ret;
	auto location = document.offsetToBytes(params.location);
	scope codeText = document.rawText.idup;
	auto code = backend.best!DCDExtComponent(file).implement(codeText,
			cast(int) location).getYield.strip;
	if (!code.length)
		return ret;
	auto brace = codeText.indexOf('{', location);
	auto fallback = brace;
	if (brace == -1)
		brace = codeText.length;
	else
	{
		fallback = codeText.indexOf('\n', location);
		brace = codeText.indexOfAny("}\n", brace);
		if (brace == -1)
			brace = codeText.length;
	}
	code = "\n\t" ~ code.replace("\n", document.eolAt(0).toString ~ "\t") ~ "\n";
	bool inIdentifier = true;
	int depth = 0;
	foreach (i; location .. brace)
	{
		if (codeText[i].isWhite)
			inIdentifier = false;
		else if (codeText[i] == '{')
			break;
		else if (codeText[i] == ',' || codeText[i] == '!')
			inIdentifier = true;
		else if (codeText[i] == '(')
			depth++;
		else
		{
			if (depth > 0)
			{
				inIdentifier = true;
				if (codeText[i] == ')')
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
