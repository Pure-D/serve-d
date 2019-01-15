module served.ddoc;

import served.protocol;

import std.string;
import std.format;
import ddoc;


/**
 * A test function for checking `DDoc` parsing
 *
 * Params:
 *     hello = a string
 *     world = an integer
 *
 * Author: Jonny
 * Bugs: None
 * ---
 * import std.stdio;
 *
 * int main(string[] args) {
 * 	   writeln("Testing inline code")
 * }
 * ---
 */
private int testFunction(string foo, int bar)
{
	import std.stdio : writeln;
	writeln(foo, bar);
	return 0;
}


/**
 * Convert a Ddoc comment string to markdown. Returns ddoc string back if it is
 * not valid.
 * Params:
 *		ddoc = string of a valid Ddoc comment.
 */
string ddocToMarkdown(string ddoc)
{
	// Parse ddoc. Return if exception.
	Comment comment;
	try
	{
		comment = parseComment(prepareDDoc(ddoc), markdownMacros);
	}
	catch (Exception e)
	{
		return ddoc;
	}

	auto output = "";
	foreach(Section section; comment.sections)
	{
		import std.uni : toLower;
		switch(section.name.toLower)
		{
		case "":
		case "summary":
			output ~= section.content ~= "\n\n";
			break;
		case "params":
			output ~= "**Params**\n\n";
			foreach (parameter; section.mapping)
			{
				output ~= format!"`%s` %s\n\n"(parameter[0], parameter[1]);
			}
			break;
		case "author":
		case "authors":
		case "bugs":
		case "date":
		case "deprecated":
		case "history":
		default:
			// Single line sections go on the same line as section titles. Multi
			// line sections go on the line below.
			import std.algorithm : find;
			if (section.content.chomp().find('\n').empty)
			{
				output ~= format!"**%s** — %s\n\n"(section.name, section.content.chomp());
			}
			else
			{
				output ~= format!"**%s**\n\n%s\n\n"(section.name, section.content.chomp());
			}
			break;
		}
	}
	return output.replace("&#36;", "$");
}

/**
 * Convert a DDoc comment string to MarkedString (as defined in the language
 * server spec)
 * Params:
 *		ddoc = A DDoc string to be converted to Markdown
 */
MarkedString[] ddocToMarked(string ddoc)
{
	MarkedString[] ret;
	if (!ddoc.length)
		return ret;

	auto md = ddoc.ddocToMarkdown;

	ret ~= MarkedString("");

	foreach (line; md.lineSplitter!(KeepTerminator.yes))
	{
		if (line.strip == "```d")
			ret ~= MarkedString("", "d");
		else if (line.strip == "```")
			ret ~= MarkedString("");
		else
			ret[$ - 1].value ~= line;
	}

	return ret;
}

/**
 * Performs preprocessing of the document. Wraps code blocks in macros.
 * Params:
 * 		str = This is one of the params
 */
private string prepareDDoc(string str)
{
	import ddoc.lexer : Lexer;

	auto lex = Lexer(str, true);
	string output;
	foreach (tok; lex)
	{
		if (tok.type == Type.embedded || tok.type == Type.inlined)
		{
			// Add newlines before documentation
			if (tok.type == Type.embedded)
			{
				output ~= "\n\n";
			}
			output ~= tok.type == Type.embedded ? "$(D_CODE " : "$(DDOC_BACKQUOTED ";
			output ~= tok.text;
			output ~= ")";
		}
		else
		{
			output ~= tok.text;
		}
	}
	return output;
}

private string[string] markdownMacros;
shared static this()
{
	//dfmt off
	markdownMacros = [
		`B` : `**$0**`,
		`I` : `*$0*`,
		`U` : `<u>$0</u>`,
		`P` : `

$0

`,
		`BR` : "\n\n",
		`DL` : `$0`,
		`DT` : `**$0**`,
		`DD` : `

* $0`,
		`TABLE` : `$0`,
		`TR` : `$0|`,
		`TH` : `| **$0** `,
		`TD` : `| $0 `,
		`OL` : `$0`,
		`UL` : `$0`,
		`LI` : `* $0`,
		`LINK` : `[$0]$(LPAREN)$0$(RPAREN)`,
		`LINK2` : `[$+]$(LPAREN)$1$(RPAREN)`,
		`LPAREN` : `(`,
		`RPAREN` : `)`,
		`DOLLAR` : `$`,
		`BACKTICK` : "`",
		`DEPRECATED` : `$0`,
		`RED` : `<font color=red>**$0**</font>`,
		`BLUE` : `<font color=blue>$0</font>`,
		`GREEN` : `<font color=green>$0</font>`,
		`YELLOW` : `<font color=yellow>$0</font>`,
		`BLACK` : `<font color=black>$0</font>`,
		`WHITE` : `<font color=white>$0</font>`,
		`D_CODE` : "$(BACKTICK)$(BACKTICK)$(BACKTICK)d
$0
$(BACKTICK)$(BACKTICK)$(BACKTICK)",
		`D_INLINECODE` : "$(BACKTICK)$0$(BACKTICK)",
		`D` : "$(BACKTICK)$0$(BACKTICK)",
		`D_COMMENT` : "$(BACKTICK)$0$(BACKTICK)",
		`D_STRING` : "$(BACKTICK)$0$(BACKTICK)",
		`D_KEYWORD` : "$(BACKTICK)$0$(BACKTICK)",
		`D_PSYMBOL` : "$(BACKTICK)$0$(BACKTICK)",
		`D_PARAM` : "$(BACKTICK)$0$(BACKTICK)",
		`DDOC` : `# $(TITLE)

$(BODY)`,
		`DDOC_BACKQUOTED` : `$(D_INLINECODE $0)`,
		`DDOC_COMMENT` : ``,
		`DDOC_DECL` : `$(DT $(BIG $0))`,
		`DDOC_DECL_DD` : `$(DD $0)`,
		`DDOC_DITTO` : `$(BR)$0`,
		`DDOC_SECTIONS` : `$0`,
		`DDOC_SUMMARY` : `$0$(BR)$(BR)`,
		`DDOC_DESCRIPTION` : `$0$(BR)$(BR)`,
		`DDOC_AUTHORS` : "$(B Authors:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_BUGS` : "$(RED BUGS:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_COPYRIGHT` : "$(B Copyright:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_DATE` : "$(B Date:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_DEPRECATED` : "$(RED Deprecated:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_EXAMPLES` : "$(B Examples:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_HISTORY` : "$(B History:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_LICENSE` : "$(B License:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_RETURNS` : "$(B Returns:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_SEE_ALSO` : "$(B See Also:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_STANDARDS` : "$(B Standards:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_THROWS` : "$(B Throws:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_VERSION` : "$(B Version:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_SECTION_H` : `$(B $0)$(BR)$(BR)`,
		`DDOC_SECTION` : `$0$(BR)$(BR)`,
		`DDOC_MEMBERS` : `$(DL $0)`,
		`DDOC_MODULE_MEMBERS` : `$(DDOC_MEMBERS $0)`,
		`DDOC_CLASS_MEMBERS` : `$(DDOC_MEMBERS $0)`,
		`DDOC_STRUCT_MEMBERS` : `$(DDOC_MEMBERS $0)`,
		`DDOC_ENUM_MEMBERS` : `$(DDOC_MEMBERS $0)`,
		`DDOC_TEMPLATE_MEMBERS` : `$(DDOC_MEMBERS $0)`,
		`DDOC_ENUM_BASETYPE` : `$0`,
		`DDOC_PARAMS` : "$(B Params:)$(BR)\n$(TABLE $0)$(BR)",
		`DDOC_PARAM_ROW` : `$(TR $0)`,
		`DDOC_PARAM_ID` : `$(TD $0)`,
		`DDOC_PARAM_DESC` : `$(TD $0)`,
		`DDOC_BLANKLINE` : `$(BR)$(BR)`,

		`DDOC_ANCHOR` : `<a name="$1"></a>`,
		`DDOC_PSYMBOL` : `$(U $0)`,
		`DDOC_PSUPER_SYMBOL` : `$(U $0)`,
		`DDOC_KEYWORD` : `$(B $0)`,
		`DDOC_PARAM` : `$(I $0)`];
	//dfmt on
}

unittest
{
	void assertEqual(A, B)(A a, B b)
	{
		import std.conv : to;

		assert(a == b, a.to!string ~ " is not equal to " ~ b.to!string);
	}

	auto comment = "Quick example of a comment\n"
		~ "&#36;(D something, else) is *a\n"
		~ "------------\n"
		~ "test\n"
		~ "/** this is some test code */\n"
		~ "assert (whatever);\n"
		~ "---------\n"
		~ "Params:\n"
		~ "	a = $(B param)\n"
		~ "Returns:\n"
		~ "	nothing of consequence";

	auto commentMarkdown = "Quick example of a comment\n"
		~ "$(D something, else) is *a\n"
		~ "\n"
		~ "```d\n"
		~ "test\n"
		~ "/** this is some test code */\n"
		~ "assert (whatever);\n"
		~ "```\n\n"
		~ "`a` **param**\n\n"
		~ "*Returns* — nothing of consequence\n\n";

	assertEqual(ddocToMarkdown(comment), commentMarkdown);
}
