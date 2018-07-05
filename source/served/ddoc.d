module served.ddoc;

import served.protocol;

import std.string;
import ddoc;

string ddocToMarkdown(string ddoc)
{
	auto lexer = Lexer(prepareDDoc(ddoc), true);
	return expand(lexer, markdownMacros).replace("&#36;", "$");
}

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

string prepareDDoc(string str)
{
	import ddoc.lexer;

	auto lex = Lexer(str, true);
	string output;
	bool wasHeader = false;
	bool hadWhitespace = false;
	bool insertNewlineIntoPos = false;
	bool wroteSomething = false;
	size_t newlinePos = 0;
	int numNewlines = 0;
	foreach (tok; lex)
	{
		if (tok.type == Type.embedded || tok.type == Type.inlined)
		{
			if (tok.type == Type.embedded)
			{
				if (numNewlines == 0)
					output ~= "\n\n";
				else if (numNewlines == 1)
					output ~= "\n";
			}
			output ~= tok.type == Type.embedded ? "$(D_CODE " : "$(DDOC_BACKQUOTED ";
			output ~= tok.text;
			output ~= ")";
		}
		else if (tok.type == Type.newline)
		{
			numNewlines++;
			if (insertNewlineIntoPos)
			{
				output = output[0 .. newlinePos] ~ "\n" ~ output[newlinePos .. $];
				insertNewlineIntoPos = false;
			}
			if (wasHeader)
				output ~= "\n";
			output ~= tok.text;
			newlinePos = output.length;
			hadWhitespace = false;
			wroteSomething = false;
		}
		else if (tok.type == Type.whitespace)
		{
			insertNewlineIntoPos = false;
			hadWhitespace = true;
			if (wroteSomething)
				output ~= tok.text;
		}
		else
		{
			numNewlines = 0;
			insertNewlineIntoPos = false;
			if (!hadWhitespace && tok.text.length && tok.text[$ - 1] == ':')
				insertNewlineIntoPos = true;
			output ~= tok.text;
			wroteSomething = true;
		}
		wasHeader = tok.text.length && tok.text[$ - 1] == ':';
	}
	return output;
}

string[string] markdownMacros;

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

	auto md = ddocToMarkdown(`&#36;(D something, else) is *a
------------
test
/** this is some test code */
assert (whatever);
---------
Params:
	a = $(B param)
Returns:
	nothing of consequence`);
	assertEqual(md, "$(D something, else) is *a

```d
test
/** this is some test code */
assert (whatever);
```

Params:

a = **param**

Returns:

nothing of consequence");
}
