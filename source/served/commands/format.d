module served.commands.format;

import served.extension;
import served.types;

import workspaced.api;
import workspaced.com.snippets : SnippetLevel;
import workspaced.coms;

import std.conv : to;
import std.json;
import std.string;

shared string gFormattingOptionsApplyOn;
shared FormattingOptions gFormattingOptions;

private static immutable string lotsOfSpaces = "                        ";
string indentString(const FormattingOptions options)
{
	if (options.insertSpaces)
	{
		// why would you use spaces?
		if (options.tabSize < lotsOfSpaces.length)
			return lotsOfSpaces[0 .. options.tabSize];
		else
		{
			// really?! you just want to see me suffer
			char[] ret = new char[options.tabSize];
			ret[] = ' ';
			return (() @trusted => cast(string) ret)();
		}
	}
	else
		return "\t"; // this is my favorite user
}

string[] generateDfmtArgs(const ref UserConfiguration config, EolType overrideEol)
{
	string[] args;
	if (config.d.overrideDfmtEditorconfig)
	{
		int maxLineLength = 120;
		int softMaxLineLength = 80;
		if (config.editor.rulers.length == 1)
		{
			softMaxLineLength = maxLineLength = config.editor.rulers[0];
		}
		else if (config.editor.rulers.length >= 2)
		{
			maxLineLength = config.editor.rulers[$ - 1];
			softMaxLineLength = config.editor.rulers[$ - 2];
		}
		FormattingOptions options = gFormattingOptions;
		//dfmt off
		args = [
			"--align_switch_statements", config.dfmt.alignSwitchStatements.to!string,
			"--brace_style", config.dfmt.braceStyle,
			"--end_of_line", overrideEol.to!string,
			"--indent_size", options.tabSize.to!string,
			"--indent_style", options.insertSpaces ? "space" : "tab",
			"--max_line_length", maxLineLength.to!string,
			"--soft_max_line_length", softMaxLineLength.to!string,
			"--outdent_attributes", config.dfmt.outdentAttributes.to!string,
			"--space_after_cast", config.dfmt.spaceAfterCast.to!string,
			"--split_operator_at_line_end", config.dfmt.splitOperatorAtLineEnd.to!string,
			"--tab_width", options.tabSize.to!string,
			"--selective_import_space", config.dfmt.selectiveImportSpace.to!string,
			"--space_before_function_parameters", config.dfmt.spaceBeforeFunctionParameters.to!string,
			"--compact_labeled_statements", config.dfmt.compactLabeledStatements.to!string,
			"--template_constraint_style", config.dfmt.templateConstraintStyle,
			"--single_template_constraint_indent", config.dfmt.singleTemplateConstraintIndent.to!string,
			"--space_before_aa_colon", config.dfmt.spaceBeforeAAColon.to!string,
			"--keep_line_breaks", config.dfmt.keepLineBreaks.to!string,
		];
		//dfmt on
	}
	return args;
}

void tryFindFormattingSettings(UserConfiguration config, Document document)
{
	gFormattingOptions.tabSize = 4;
	gFormattingOptions.insertSpaces = false;
	bool hadOneSpace;
	foreach (line; document.rawText.lineSplitter)
	{
		auto whitespace = line[0 .. line.length - line.stripLeft.length];
		if (whitespace.startsWith("\t"))
		{
			gFormattingOptions.insertSpaces = false;
		}
		else if (whitespace == " ")
		{
			hadOneSpace = true;
		}
		else if (whitespace.length >= 2)
		{
			gFormattingOptions.tabSize = hadOneSpace ? 1 : cast(int) whitespace.length;
			gFormattingOptions.insertSpaces = true;
		}
	}

	if (config.editor.tabSize != 0)
		gFormattingOptions.tabSize = config.editor.tabSize;
}

@protocolMethod("textDocument/formatting")
TextEdit[] provideFormatting(DocumentFormattingParams params)
{
	auto config = workspace(params.textDocument.uri).config;
	if (!config.d.enableFormatting)
		return [];
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	gFormattingOptionsApplyOn = params.textDocument.uri;
	gFormattingOptions = params.options;
	auto result = backend.get!DfmtComponent.format(document.rawText,
			generateDfmtArgs(config, document.eolAt(0))).getYield;
	return diff(document, result);
}

string formatCode(string code, string[] dfmtArgs)
{
	return backend.get!DfmtComponent.format(code, dfmtArgs).getYield;
}

string formatSnippet(string code, string[] dfmtArgs, SnippetLevel level = SnippetLevel.global)
{
	return backend.get!SnippetsComponent.format(code, dfmtArgs, level).getYield;
}

@protocolMethod("textDocument/rangeFormatting")
TextEdit[] provideRangeFormatting(DocumentRangeFormattingParams params)
{
	import std.algorithm : filter;
	import std.array : array;

	return provideFormatting(DocumentFormattingParams(params.textDocument, params
			.options))
		.filter!(
				(edit) => edit.range.intersects(params.range)
		).array;
}

private TextEdit[] diff(Document document, const string after)
{
	import std.ascii : isWhite;
	import std.utf : decode;

	auto before = document.rawText();
	size_t i;
	size_t j;
	TextEdit[] result;

	size_t startIndex;
	size_t stopIndex;
	string text;

	Position cachePosition;
	size_t cacheIndex;

	bool pushTextEdit()
	{
		if (startIndex != stopIndex || text.length > 0)
		{
			auto startPosition = document.movePositionBytes(cachePosition, cacheIndex, startIndex);
			auto stopPosition = document.movePositionBytes(startPosition, startIndex, stopIndex);
			cachePosition = stopPosition;
			cacheIndex = stopIndex;
			result ~= TextEdit([startPosition, stopPosition], text);
			return true;
		}

		return false;
	}

	while (i < before.length || j < after.length)
	{
		auto newI = i;
		auto newJ = j;
		dchar beforeChar;
		dchar afterChar;

		if (newI < before.length)
		{
			beforeChar = decode(before, newI);
		}

		if (newJ < after.length)
		{
			afterChar = decode(after, newJ);
		}

		if (i < before.length && j < after.length && beforeChar == afterChar)
		{
			i = newI;
			j = newJ;

			if (pushTextEdit())
			{
				startIndex = stopIndex;
				text = "";
			}
		}

		if (startIndex == stopIndex)
		{
			startIndex = i;
			stopIndex = i;
		}

		auto addition = !isWhite(beforeChar) && isWhite(afterChar);
		immutable deletion = isWhite(beforeChar) && !isWhite(afterChar);

		if (!addition && !deletion)
		{
			addition = before.length - i < after.length - j;
		}

		if (addition && j < after.length)
		{
			text ~= after[j .. newJ];
			j = newJ;
		}
		else if (i < before.length)
		{
			stopIndex = newI;
			i = newI;
		}
	}

	pushTextEdit();
	return result;
}

unittest
{
	import std.stdio;

	TextEdit[] test(string from, string after)
	{
		// fix assert equals tests on windows with token-strings comparing with regular strings
		from = from.replace("\r\n", "\n");
		after = after.replace("\r\n", "\n");

		Document d = Document.nullDocument(from);
		auto ret = diff(d, after);
		foreach_reverse (patch; ret)
			d.applyChange(patch.range, patch.newText);
		assert(d.rawText == after);
		// writefln("diff[%d]: %s", ret.length, ret);
		return ret;
	}

	// text replacement tests just in case some future changes are made this way
	test("text", "after");
	test("completely", "diffrn");
	test("complete", "completely");
	test("build", "built");
	test("test", "tetestst");
	test("tetestst", "test");

	// UTF-32
	test("// \U0001FA00\nvoid main() {}", "// \U0001FA00\n\nvoid main()\n{\n}");

	// otherwise dfmt only changes whitespaces
	assert(test("import std.stdio;\n\nvoid main()\n{\n\twriteln();\n}\n",
			"\timport std.stdio;\n\n\tvoid main()\n\t{\n\t\twriteln();\n\t}\n") == [
			TextEdit([Position(0, 0), Position(0, 0)], "\t"),
			TextEdit([Position(2, 0), Position(2, 0)], "\t"),
			TextEdit([Position(3, 0), Position(3, 0)], "\t"),
			TextEdit([Position(4, 1), Position(4, 1)], "\t"),
			TextEdit([Position(5, 0), Position(5, 0)], "\t")
			]);
	assert(test(
			"\timport std.stdio;\n\n\tvoid main()\n\t{\n\t\twriteln();\n\t}\n",
			"import std.stdio;\n\nvoid main()\n{\n\twriteln();\n}\n") == [
			TextEdit(
				[Position(0, 0), Position(0, 1)], ""),
			TextEdit([Position(2, 0), Position(2, 1)], ""),
			TextEdit([Position(3, 0), Position(3, 1)], ""),
			TextEdit([Position(4, 1), Position(4, 2)], ""),
			TextEdit([Position(5, 0), Position(5, 1)], "")
			]);
	assert(test("import std.stdio;void main(){writeln();}",
			"import std.stdio;\n\nvoid main()\n{\n\twriteln();\n}\n") == [
			TextEdit(
				[Position(0, 17), Position(0, 17)], "\n\n"),
			TextEdit([Position(0, 28), Position(0, 28)], "\n"),
			TextEdit([Position(0, 29), Position(0, 29)], "\n\t"),
			TextEdit([Position(0, 39), Position(0, 39)], "\n"),
			TextEdit([Position(0, 40), Position(0, 40)], "\n")
			]);
	assert(test("", "void foo()\n{\n\tcool();\n}\n") == [
			TextEdit([Position(0, 0), Position(0, 0)], "void foo()\n{\n\tcool();\n}\n")
			]);
	assert(test("void foo()\n{\n\tcool();\n}\n", "") == [
			TextEdit([Position(0, 0), Position(4, 0)], "")
			]);

	assert(test(q{if (x)
  foo();
else
{
  bar();
}}, q{if (x) {
  foo();
} else {
  bar();
}}) == [
			TextEdit([Position(0, 6), Position(1, 2)], " {\n  "),
			TextEdit([Position(2, 0), Position(2, 0)], "} "),
			TextEdit([Position(2, 4), Position(3, 0)], " ")
			]);

	assert(test(q{DocumentUri  uriFromFile (string file) {
	import std.uri :encodeComponent;
	if(! isAbsolute(file))  throw new Exception("Tried to pass relative path '" ~ file ~ "' to uriFromFile");
	file = file.buildNormalizedPath.replace("\\", "/");
	if (file.length == 0) return "";
	if (file[0] != '/') file = '/'~file; // always triple slash at start but never quad slash
	if (file.length >= 2 && file[0.. 2] == "//")// Shares (\\share\bob) are different somehow
		file = file[2 .. $];
	return "file://"~file.encodeComponent.replace("%2F", "/");
}

string uriToFile(DocumentUri uri)
{
	import std.uri : decodeComponent;
	import std.string : startsWith;

	if (uri.startsWith("file://"))
	{
		string ret = uri["file://".length .. $].decodeComponent;
		if (ret.length >= 3 && ret[0] == '/' && ret[2] == ':')
			return ret[1 .. $].replace("/", "\\");
		else if (ret.length >= 1 && ret[0] != '/')
			return "\\\\" ~ ret.replace("/", "\\");
		return ret;
	}
	else
		return null;
}}, q{DocumentUri uriFromFile(string file)
{
	import std.uri : encodeComponent;

	if (!isAbsolute(file))
		throw new Exception("Tried to pass relative path '" ~ file ~ "' to uriFromFile");
	file = file.buildNormalizedPath.replace("\\", "/");
	if (file.length == 0)
		return "";
	if (file[0] != '/')
		file = '/' ~ file; // always triple slash at start but never quad slash
	if (file.length >= 2 && file[0 .. 2] == "//") // Shares (\\share\bob) are different somehow
		file = file[2 .. $];
	return "file://" ~ file.encodeComponent.replace("%2F", "/");
}

string uriToFile(DocumentUri uri)
{
	import std.uri : decodeComponent;
	import std.string : startsWith;

	if (uri.startsWith("file://"))
	{
		string ret = uri["file://".length .. $].decodeComponent;
		if (ret.length >= 3 && ret[0] == '/' && ret[2] == ':')
			return ret[1 .. $].replace("/", "\\");
		else if (ret.length >= 1 && ret[0] != '/')
			return "\\\\" ~ ret.replace("/", "\\");
		return ret;
	}
	else
		return null;
}}) == [
	TextEdit([Position(0, 12), Position(0, 13)], ""),
	TextEdit([Position(0, 24), Position(0, 25)], ""),
	TextEdit([Position(0, 38), Position(0, 39)], "\n"),
	TextEdit([Position(1, 17), Position(1, 17)], " "),
	TextEdit([Position(2, 0), Position(2, 0)], "\n"),
	TextEdit([Position(2, 3), Position(2, 3)], " "),
	TextEdit([Position(2, 5), Position(2, 6)], ""),
	TextEdit([Position(2, 23), Position(2, 25)], "\n\t\t"),
	TextEdit([Position(4, 22), Position(4, 23)], "\n\t\t"),
	TextEdit([Position(5, 20), Position(5, 21)], "\n\t\t"),
	TextEdit([Position(5, 31), Position(5, 31)], " "),
	TextEdit([Position(5, 32), Position(5, 32)], " "),
	TextEdit([Position(6, 31), Position(6, 31)], " "),
	TextEdit([Position(6, 45), Position(6, 45)], " "),
	TextEdit([Position(8, 17), Position(8, 17)], " "),
	TextEdit([Position(8, 18), Position(8, 18)], " ")
]);
}
