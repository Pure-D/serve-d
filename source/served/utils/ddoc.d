module served.utils.ddoc;

import served.lsp.protocol;

import ddoc;

import std.algorithm;
import std.array;
import std.format;
import std.range.primitives;
import std.string;
import std.uni : sicmp;

public import ddoc : Comment;

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
 * Parses a ddoc string into a divided comment.
 * Returns: A comment if the ddoc could be parsed or Comment.init if it couldn't be parsed and throwError is false.
 * Throws: Exception if comment has ddoc syntax errors.
 * Params:
 * 	ddoc = the documentation string as given by the user without any comment markers
 * 	throwError = set to true to make parsing errors throw
 */
Comment parseDdoc(string ddoc, bool throwError = false)
{
	if (ddoc.length == 0)
		return Comment.init;

	if (throwError)
		return parseComment(prepareDDoc(ddoc), markdownMacros, false);
	else
	{
		try
		{
			return parseComment(prepareDDoc(ddoc), markdownMacros, false);
		}
		catch (Exception e)
		{
			return Comment.init;
		}
	}
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
		comment = parseComment(prepareDDoc(ddoc), markdownMacros, false);
	}
	catch (Exception e)
	{
		return ddoc;
	}
	return ddocToMarkdown(comment);
}

/// ditto
string ddocToMarkdown(const Comment comment)
{
	auto output = "";
	foreach (section; comment.sections)
	{
		import std.uni : toLower;

		string content = section.content.postProcessContent;
		switch (section.name.toLower)
		{
		case "":
		case "summary":
			output ~= content ~ "\n\n";
			break;
		case "params":
			output ~= "**Params**\n\n";
			foreach (parameter; section.mapping)
			{
				output ~= format!"`%s` %s\n\n"(parameter[0].postProcessContent,
						parameter[1].postProcessContent);
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
			import std.algorithm : canFind;

			content = content.chomp();
			if (!content.canFind("\n"))
			{
				output ~= format!"**%s** — %s\n\n"(section.name, content);
			}
			else
			{
				output ~= format!"**%s**\n\n%s\n\n"(section.name, content);
			}
			break;
		}
	}
	return output.replace("&#36;", "$");
}

/// Removes leading */+ characters from each line per section if the entire section only consists of them. Sections are separated with lines starting with ---
private string preProcessContent(string content)
{
	bool hasLeadingStarOrPlus;
	foreach (chunk; content.lineSplitter!(KeepTerminator.yes)
			.chunkBy!(a => a.startsWith("---")))
	{
		foreach (line; chunk[1])
		{
			if (line.stripLeft.startsWith("*", "+"))
			{
				hasLeadingStarOrPlus = true;
				break;
			}
		}

		if (hasLeadingStarOrPlus)
			break;
	}

	if (!hasLeadingStarOrPlus)
		return content; // no leading * or + characters, no preprocessing needed.

	auto newContent = appender!string();
	newContent.reserve(content.length);
	foreach (chunk; content.lineSplitter!(KeepTerminator.yes)
			.chunkBy!(a => a.startsWith("---")))
	{
		auto c = chunk[1].save;

		bool isStrippable = true;
		foreach (line; c)
		{
			auto l = line.stripLeft;
			if (!l.length)
				continue;
			if (!l.startsWith("*", "+"))
			{
				isStrippable = false;
				break;
			}
		}

		if (isStrippable)
		{
			foreach (line; chunk[1])
			{
				auto stripped = line.stripLeft;
				if (!stripped.length)
					stripped = line;

				if (stripped.startsWith("* ", "+ ", "*\t", "+\t"))
					newContent.put(stripped[2 .. $]);
				else if (stripped.startsWith("*", "+"))
					newContent.put(stripped[1 .. $]);
				else
					newContent.put(line);
			}
		}
		else
			foreach (line; chunk[1])
				newContent.put(line);
	}
	return newContent.data;
}

unittest
{
	string noChange = `Params:
	a = this does things
	b = this does too

Examples:
---
foo(a, b);
---
`;
	assert(preProcessContent(noChange) is noChange);

	assert(preProcessContent(`* Params:
*     a = this does things
*     b = this does too
*
* cool.`) == `Params:
    a = this does things
    b = this does too

cool.`);
}

/// Fixes code-d specific placeholders inserted during ddoc translation for better IDE integration.
private string postProcessContent(string content)
{
	while (true)
	{
		auto index = content.indexOf(inlineRefPrefix);
		if (index != -1)
		{
			auto end = content.indexOf('.', index + inlineRefPrefix.length);
			if (end == -1)
				break; // malformed
			content = content[0 .. index]
				~ content[index + inlineRefPrefix.length .. end].postProcessInlineRefPrefix
				~ content[end .. $];
		}

		if (index == -1)
			break;
	}
	return content;
}

private string postProcessInlineRefPrefix(string content)
{
	return content.splitter(',').map!strip.join('.');
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
	return markdownToMarked(ddoc.ddocToMarkdown);
}

/// ditto
MarkedString[] ddocToMarked(const Comment comment)
{
	MarkedString[] ret;
	if (comment == Comment.init)
		return ret;
	return markdownToMarked(comment.ddocToMarkdown);
}

/**
 * Converts markdown code to MarkedString blocks as determined by D code blocks.
 */
MarkedString[] markdownToMarked(string md)
{
	MarkedString[] ret;
	if (!md.length)
		return ret;

	ret ~= MarkedString("");

	foreach (line; md.lineSplitter!(KeepTerminator.yes))
	{
		if (line.strip == "```d")
			ret ~= MarkedString("", "d");
		else if (line.strip == "```")
			ret ~= MarkedString("", "text");
		else
			ret[$ - 1].value ~= line;
	}

	if (ret.length >= 2 && !ret[$ - 1].value.strip.length)
		ret = ret[0 .. $ - 1];

	return ret;
}

/**
 * Returns: the params section in a ddoc comment as key value pair. Or null if not found.
 */
inout(KeyValuePair[]) getParams(inout Comment comment)
{
	foreach (section; comment.sections)
		if (section.name.sicmp("params") == 0)
			return section.mapping;
	return null;
}

/**
 * Returns: documentation for a given parameter in the params section of a documentation comment. Or null if not found.
 */
string getParamDocumentation(const Comment comment, string searchParam)
{
	foreach (param; getParams(comment))
		if (param[0] == searchParam)
			return param[1];
	return null;
}

/**
 * Performs preprocessing of the document. Wraps code blocks in macros.
 * Params:
 * 		str = This is one of the params
 */
private string prepareDDoc(string str)
{
	import ddoc.lexer : Lexer;

	str = str.preProcessContent;

	auto lex = Lexer(str, true);
	auto output = appender!string;

	void process(const(Token) tok)
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
		else if (tok.type == Type.dollar)
		{
			lex.popFront;
			if (lex.empty)
				output ~= "$";
			else if (lex.front.type != Type.lParen)
			{
				output ~= "$";
				process(lex.front);
			}
			else
			{
				lex.popFront;
				if (lex.empty)
					output ~= "$(";
				else if (lex.front.text.isSpecialMacro)
				{
					matchSpecialMacro(output, lex);
				}
				else
				{
					output ~= "$(";
					process(lex.front);
				}
			}
		}
		else
		{
			output ~= tok.text;
		}
	}

	while (!lex.empty)
	{
		process(lex.front);
		lex.popFront;
	}
	return output.data;
}

bool isSpecialMacro(string macroName)
{
	return macroName == "TABLE2"
		|| macroName == "P";
}

string processSpecialMacro(string macroName, string ddoc)
{
	if (macroName == "TABLE2")
	{
		auto parts = ddoc.findSplit(",");
		return parts[0] // table heading
			~ "\n\n"
			~ processDdocTableMacro(parts[2]);
	}
	else if (macroName == "P")
	{
		string dedented(string s)
		{
			auto leadingSpaces = s[0 .. $ - s.stripLeft.length];
			return s
				.lineSplitter!(KeepTerminator.yes)
				.map!(line => line.startsWith(leadingSpaces) ? line[leadingSpaces.length .. $] : line)
				.join();
		}

		if (ddoc.startsWith("\r\n"))
		{
			ddoc = ddoc[2 .. $];
			return "$(P\n" ~ dedented(ddoc) ~ ")";
		}
		else if (ddoc.startsWith("\n", "\r"))
		{
			ddoc = ddoc[1 .. $];
			return "$(P\n" ~ dedented(ddoc) ~ ")";
		}
		else
			return "$(P " ~ ddoc ~ ")";
	}
	else
		assert(false, "Unknown special macro, don't know why this method was called");
}

unittest
{
	assert(processSpecialMacro("TABLE2", `getFunctionVariadicStyle,
    $(THEAD result, kind, access, example)
    $(TROW $(D "none"), not a variadic function, $(NBSP), $(D void foo();))
    $(TROW $(D "argptr"), D style variadic function, $(D _argptr) and $(D _arguments), $(D void bar(...)))
    $(TROW $(D "stdarg"), C style variadic function, $(LINK2 $(ROOT_DIR)phobos/core_stdc_stdarg.html, $(D core.stdc.stdarg)), $(D extern (C) void abc(int, ...)))
    $(TROW $(D "typesafe"), typesafe variadic function, array on stack, $(D void def(int[] ...)))
`) == `getFunctionVariadicStyle

| result | kind | access | example |
| --- | --- | --- | --- |
| $(D "none") | not a variadic function | $(NBSP) | $(D void foo();) |
| $(D "argptr") | D style variadic function | $(D _argptr) and $(D _arguments) | $(D void bar(...)) |
| $(D "stdarg") | C style variadic function | $(LINK2 $(ROOT_DIR)phobos/core_stdc_stdarg.html, $(D core.stdc.stdarg)) | $(D extern (C) void abc(int, ...)) |
| $(D "typesafe") | typesafe variadic function | array on stack | $(D void def(int[] ...)) |
`, processSpecialMacro("TABLE2", `getFunctionVariadicStyle,
    $(THEAD result, kind, access, example)
    $(TROW $(D "none"), not a variadic function, $(NBSP), $(D void foo();))
    $(TROW $(D "argptr"), D style variadic function, $(D _argptr) and $(D _arguments), $(D void bar(...)))
    $(TROW $(D "stdarg"), C style variadic function, $(LINK2 $(ROOT_DIR)phobos/core_stdc_stdarg.html, $(D core.stdc.stdarg)), $(D extern (C) void abc(int, ...)))
    $(TROW $(D "typesafe"), typesafe variadic function, array on stack, $(D void def(int[] ...)))
`));
}

string processDdocTableMacro(string ddoc)
{
	auto ret = appender!string;
	int columnCount = 0;

	void processRow(bool header)
	{
		bool shouldBeHeader = columnCount == 0;
		if (header != shouldBeHeader)
		{
			// malformed table / undisplayable in markdown
			ret ~= ddoc;
			ddoc = null;
			return;
		}

		auto row = extractUntilClosingParenAndDropParen(ddoc);
		auto parts = row.splitOutsideParens;
		if (header)
			columnCount = cast(int)parts.length;
		else
		{
			while (parts.length < columnCount)
				parts ~= "";
		}

		foreach (part; parts)
		{
			ret ~= "| ";
			ret ~= part.strip;
			ret ~= " ";
		}
		ret ~= "|\n";

		if (header)
		{
			foreach (i; 0 .. columnCount)
				ret ~= "| --- ";
			ret ~= "|\n";
		}
	}

	while (ddoc.length)
	{
		ddoc = ddoc.stripLeft();
		switch (ddoc.startsWith("$(THEAD", "$(TROW"))
		{
			case 1:
				ddoc = ddoc["$(THEAD".length .. $].chompPrefix(" ");
				processRow(true);
				break;
			case 2:
				ddoc = ddoc["$(TROW".length .. $].chompPrefix(" ");
				processRow(false);
				break;
			default:
				ret ~= ddoc;
				ddoc = null;
				break;
		}
	}
	return ret.data;
}

void matchSpecialMacro(T)(ref T output, ref Lexer lex)
in (lex.front.type == Type.word)
out (; lex.empty || lex.front.type == Type.rParen)
{
	string macroName = lex.front.text;
	lex.popFront;
	auto content = appender!string;
	int depth = 1;
	while (!lex.empty)
	{
		if (lex.front.type == Type.rParen)
			depth--;
		else if (lex.front.type == Type.lParen)
			depth++;

		if (depth == 0)
			break;
		content ~= lex.front.text;
		lex.popFront;
	}

	output ~= processSpecialMacro(macroName, content.data);
}

private ptrdiff_t indexOfClosingParenBalanced(string s, ptrdiff_t i)
in(s[i] == '(')
{
	int depth = 0;
	do
	{
		if (s[i] == '(')
			depth++;
		else if (s[i] == ')')
			depth--;
	} while (depth != 0 && ++i < s.length);

	if (i >= s.length)
		return -1;
	return i;
}

private string extractUntilClosingParenAndDropParen(ref string s)
{
	string source = s;
	int depth = 1;
	while (depth > 0 && s.length)
	{
		if (s[0] == ')')
			depth--;
		else if (s[0] == '(')
			depth++;
		s = s[1 .. $];
	}
	return source[0 .. $ - s.length - (depth == 0 ? 1 : 0)];
}

private string[] splitOutsideParens(string s)
{
	string[] ret;
	size_t i;
	while (i < s.length)
	{
		auto next = s.indexOfAny("(,", i);

		while (next != -1 && s[next] == '(')
		{
			next = s.indexOfClosingParenBalanced(next);
			if (next != -1)
				next = s.indexOfAny("(,", next);
		}

		if (next == -1)
			break;

		assert(s[next] == ',');
		ret ~= s[i .. next];
		i = next + 1;
	}

	if (i != s.length)
		ret ~= s[i .. $];
	return ret;
}

unittest
{
	void testExtract(string input, string expected, string remaining)
	{
		assert(extractUntilClosingParenAndDropParen(input) == expected);
		assert(input == remaining);
	}

	testExtract("foobar", "foobar", "");
	testExtract("foo)", "foo", "");
	testExtract("foo(", "foo(", "");
	testExtract("foo) bar", "foo", " bar");
	testExtract("foo()) bar", "foo()", " bar");
	testExtract("foo(xd())) bar", "foo(xd())", " bar");

	assert(splitOutsideParens("foo, bar") == ["foo", " bar"]);
	assert(splitOutsideParens("foo(), bar") == ["foo()", " bar"]);
	assert(splitOutsideParens("foo(,), bar") == ["foo(,)", " bar"]);
	assert(splitOutsideParens("foo(a,b), bar") == ["foo(a,b)", " bar"]);
	assert(splitOutsideParens("foo(a,b), bar()") == ["foo(a,b)", " bar()"]);
	assert(splitOutsideParens("foo(a,b,)), bar(a)") == ["foo(a,b,))", " bar(a)"]);
	assert(splitOutsideParens("foo(a,b), bar(a,)") == ["foo(a,b)", " bar(a,)"]);
}

static immutable inlineRefPrefix = "__CODED_INLINE_REF__:";

string[string] markdownMacros;
static this()
{
	markdownMacros = [
		`B`: `**$0**`,
		`I`: `*$0*`,
		`U`: `<u>$0</u>`,
		`P`: `

$0

`,
		`BR`: "\n\n",
		`DL`: `$0`,
		`DT`: `**$0**`,
		`DD`: `

* $0`,
		`TABLE`: `$0`,
		`TR`: `$0|`,
		`TH`: `| **$0** `,
		`TD`: `| $0 `,
		`OL`: `$0`,
		`UL`: `$0`,
		`LI`: `* $0`,
		`LINK`: `[$0]$(LPAREN)$0$(RPAREN)`,
		`LINK2`: `[$+]$(LPAREN)$1$(RPAREN)`,
		`LPAREN`: `(`,
		`RPAREN`: `)`,
		`DOLLAR`: `$`,
		`BACKTICK`: "`",
		`COLON`: ":",
		`DEPRECATED`: `$0`,
		`LREF`: `[$(BACKTICK)$0$(BACKTICK)](command$(COLON)code-d.navigateLocal?$0)`,
		`REF`: `[$(BACKTICK)` ~ inlineRefPrefix ~ `$+.$1$(BACKTICK)](command$(COLON)code-d.navigateGlobal?`
		~ inlineRefPrefix ~ `$+.$1)`,
		`RED`: `<font color=red>**$0**</font>`,
		`BLUE`: `<font color=blue>$0</font>`,
		`GREEN`: `<font color=green>$0</font>`,
		`YELLOW`: `<font color=yellow>$0</font>`,
		`BLACK`: `<font color=black>$0</font>`,
		`WHITE`: `<font color=white>$0</font>`,
		`D_CODE`: "$(BACKTICK)$(BACKTICK)$(BACKTICK)d
$0
$(BACKTICK)$(BACKTICK)$(BACKTICK)",
		`D_INLINECODE`: "$(BACKTICK)$0$(BACKTICK)",
		`D`: "$(BACKTICK)$0$(BACKTICK)",
		`D_COMMENT`: "$(BACKTICK)$0$(BACKTICK)",
		`D_STRING`: "$(BACKTICK)$0$(BACKTICK)",
		`D_KEYWORD`: "$(BACKTICK)$0$(BACKTICK)",
		`D_PSYMBOL`: "$(BACKTICK)$0$(BACKTICK)",
		`D_PARAM`: "$(BACKTICK)$0$(BACKTICK)",
		`DDOC`: `# $(TITLE)

$(BODY)`,
		`DDOC_BACKQUOTED`: `$(D_INLINECODE $0)`,
		`DDOC_COMMENT`: ``,
		`DDOC_DECL`: `$(DT $(BIG $0))`,
		`DDOC_DECL_DD`: `$(DD $0)`,
		`DDOC_DITTO`: `$(BR)$0`,
		`DDOC_SECTIONS`: `$0`,
		`DDOC_SUMMARY`: `$0$(BR)$(BR)`,
		`DDOC_DESCRIPTION`: `$0$(BR)$(BR)`,
		`DDOC_AUTHORS`: "$(B Authors:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_BUGS`: "$(RED BUGS:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_COPYRIGHT`: "$(B Copyright:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_DATE`: "$(B Date:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_DEPRECATED`: "$(RED Deprecated:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_EXAMPLES`: "$(B Examples:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_HISTORY`: "$(B History:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_LICENSE`: "$(B License:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_RETURNS`: "$(B Returns:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_SEE_ALSO`: "$(B See Also:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_STANDARDS`: "$(B Standards:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_THROWS`: "$(B Throws:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_VERSION`: "$(B Version:)$(BR)\n$0$(BR)$(BR)",
		`DDOC_SECTION_H`: `$(B $0)$(BR)$(BR)`,
		`DDOC_SECTION`: `$0$(BR)$(BR)`,
		`DDOC_MEMBERS`: `$(DL $0)`,
		`DDOC_MODULE_MEMBERS`: `$(DDOC_MEMBERS $0)`,
		`DDOC_CLASS_MEMBERS`: `$(DDOC_MEMBERS $0)`,
		`DDOC_STRUCT_MEMBERS`: `$(DDOC_MEMBERS $0)`,
		`DDOC_ENUM_MEMBERS`: `$(DDOC_MEMBERS $0)`,
		`DDOC_TEMPLATE_MEMBERS`: `$(DDOC_MEMBERS $0)`,
		`DDOC_ENUM_BASETYPE`: `$0`,
		`DDOC_PARAMS`: "$(B Params:)$(BR)\n$(TABLE $0)$(BR)",
		`DDOC_PARAM_ROW`: `$(TR $0)`,
		`DDOC_PARAM_ID`: `$(TD $0)`,
		`DDOC_PARAM_DESC`: `$(TD $0)`,
		`DDOC_BLANKLINE`: `$(BR)$(BR)`,

		`DDOC_ANCHOR`: `<a name="$1"></a>`,
		`DDOC_PSYMBOL`: `$(U $0)`,
		`DDOC_PSUPER_SYMBOL`: `$(U $0)`,
		`DDOC_KEYWORD`: `$(B $0)`,
		`DDOC_PARAM`: `$(I $0)`,

		// from __traits() auto-completion / built-ins that the user is likely to see
		`SPEC_RUNNABLE_EXAMPLE_COMPILE`: `$0`,
		`GLINK`: `**$0**`,
		`CONSOLE`: `$(BACKTICK)$(BACKTICK)$(BACKTICK)
$0
$(BACKTICK)$(BACKTICK)$(BACKTICK)`,
	];
}

unittest
{
	//dfmt off
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
		~ "**Params**\n\n"
		~ "`a` **param**\n\n"
		~ "**Returns** — nothing of consequence\n\n";
	//dfmt on

	assert(ddocToMarkdown(comment) == commentMarkdown);
}

@("ddoc with inline references")
unittest
{
	//dfmt off
	auto comment = "creates a $(REF Exception,std, object) for this $(LREF error).";

	auto commentMarkdown = "creates a [`std.object.Exception`](command:code-d.navigateGlobal?std.object.Exception) "
			~ "for this [`error`](command:code-d.navigateLocal?error).\n\n\n\n";
	//dfmt on

	assert(ddocToMarkdown(comment) == commentMarkdown);
}

@("messed up formatting")
unittest
{
	//dfmt off
	auto comment = ` * this documentation didn't have the stars stripped
 * so we need to remove them.
 * There is more content.
---
// example code
---`;

	auto commentMarkdown = `this documentation didn't have the stars stripped
so we need to remove them.
There is more content.

` ~ "```" ~ `d
// example code
` ~ "```\n\n";
	//dfmt on

	assert(ddocToMarkdown(comment) == commentMarkdown);
}

@("long paragraph")
unittest
{
	auto comment = `$(P Takes a single argument, which must evaluate to either
a module, a struct, a union, a class, an interface, an enum, or a
template instantiation.

A sequence of string literals is returned, each of which
is the name of a member of that argument combined with all
of the members of its base classes (if the argument is a class).
No name is repeated.
Builtin properties are not included.
)`;

	auto commentMarkdown = `

Takes a single argument, which must evaluate to either
a module, a struct, a union, a class, an interface, an enum, or a
template instantiation.



A sequence of string literals is returned, each of which
is the name of a member of that argument combined with all
of the members of its base classes (if the argument is a class).
No name is repeated.
Builtin properties are not included.
)

`;
	// TODO: trailing parentheses here, because Comment.parse/splitSections split the paragraph!

	assert(ddocToMarkdown(comment) == commentMarkdown, '"' ~ ddocToMarkdown(comment) ~ '"');
}

@("indented paragraph")
unittest
{
	auto comment = `$(P
    For more information, see: $(DDSUBLINK spec/attribute, uda, User-Defined Attributes)
)`;

	auto commentMarkdown = `

For more information, see: 






`;

	assert(ddocToMarkdown(comment) == commentMarkdown, '"' ~ ddocToMarkdown(comment) ~ '"');
}
