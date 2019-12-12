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
			maxLineLength = config.editor.rulers[0];
			softMaxLineLength = maxLineLength - 40;
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
			"--compact_labeled_statements", config.dfmt.compactLabeledStatements.to!string,
			"--template_constraint_style", config.dfmt.templateConstraintStyle
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
	return [
		TextEdit(TextRange(Position(0, 0), document.offsetToPosition(document.length)), result)
	];
}

string formatCode(string code, string[] dfmtArgs)
{
	return backend.get!DfmtComponent.format(code, dfmtArgs).getYield;
}

string formatSnippet(string code, string[] dfmtArgs, SnippetLevel level = SnippetLevel.global)
{
	return backend.get!SnippetsComponent.format(code, dfmtArgs, level).getYield;
}
