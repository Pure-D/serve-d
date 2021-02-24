module served.linters.dscanner;

import std.algorithm;
import std.conv;
import std.file;
import std.json;
import std.path;
import std.string;

import served.extension;
import served.linters.diagnosticmanager;
import served.types;

import workspaced.api;
import workspaced.coms;

import workspaced.com.dscanner;

import dscanner.analysis.config : StaticAnalysisConfig, Check;

import dscanner.analysis.local_imports : LocalImportCheck;

static immutable LocalImportCheckKEY = "dscanner.suspicious.local_imports";

static immutable string DScannerDiagnosticSource = "DScanner";
static immutable string SyntaxHintDiagnosticSource = "serve-d";

//dfmt off
static immutable StaticAnalysisConfig servedDefaultDscannerConfig = {
	could_be_immutable_check: Check.disabled,
	undocumented_declaration_check: Check.disabled
};
//dfmt on

enum DiagnosticSlot = 0;

void lint(Document document)
{
	auto instance = activeInstance = backend.getBestInstance!DscannerComponent(
			document.uri.uriToFile);
	if (!instance)
		return;

	auto fileConfig = config(document.uri);
	if (!fileConfig.d.enableLinting || !fileConfig.d.enableStaticLinting)
		return;

	auto ignoredKeys = fileConfig.dscanner.ignoredKeys;

	auto ini = getDscannerIniForDocument(document.uri, instance);
	auto issues = instance.get!DscannerComponent.lint(document.uri.uriToFile,
			ini, document.rawText, false, servedDefaultDscannerConfig).getYield;
	Diagnostic[] result;

	foreach (issue; issues)
	{
		if (ignoredKeys.canFind(issue.key))
			continue;
		Diagnostic d;
		scope text = document.lineAtScope(cast(uint) issue.line - 1).stripRight;
		string keyNormalized = issue.key.startsWith("dscanner.")
			? issue.key["dscanner.".length .. $] : issue.key;
		if (text.canFind("@suppress(all)", "@suppress:all",
				"@suppress(" ~ issue.key ~ ")", "@suppress:" ~ issue.key,
				"@suppress(" ~ keyNormalized ~ ")", "@suppress:" ~ keyNormalized) || text
				.endsWith("stfu"))
			continue;

		if (!d.adjustRangeForType(document, issue))
			continue;
		d.adjustSeverityForType(document, issue);

		if (!d.source.isNull && d.source.get.length)
		{
			// handled by previous functions
			result ~= d;
			continue;
		}

		d.source = DScannerDiagnosticSource;
		d.message = issue.description;
		d.code = JSONValue(issue.key);
		result ~= d;
	}

	createDiagnosticsFor!DiagnosticSlot(document.uri) = result;
	updateDiagnostics(document.uri);
}

void clear()
{
	diagnostics[DiagnosticSlot] = null;
	updateDiagnostics();
}

string getDscannerIniForDocument(DocumentUri document, WorkspaceD.Instance instance = null)
{
	if (!instance)
		instance = backend.getBestInstance!DscannerComponent(document.uriToFile);

	if (!instance)
		return "dscanner.ini";

	auto ini = buildPath(instance.cwd, "dscanner.ini");
	if (!exists(ini))
		ini = "dscanner.ini";
	return ini;
}

/// Sets the range for the diagnostic from the issue
/// Returns: `false` if this issue should be discarded (handled by other issues)
bool adjustRangeForType(ref Diagnostic d, Document document, DScannerIssue issue)
{
	auto p = Position(cast(uint) issue.line - 1, cast(uint) issue.column - 1);
	d.range = TextRange(p, p);
	switch (issue.key)
	{
	case null:
		// syntax errors
		return adjustRangeForSyntaxError(d, document, issue);
	case LocalImportCheckKEY:
		if (adjustRangeForLocalImportsError(d, document, issue))
			return true;
		goto default;
	default:
		d.range = document.wordRangeAt(p);
		return true;
	}
}

private bool adjustRangeForSyntaxError(ref Diagnostic d, Document document, DScannerIssue issue)
{
	auto s = issue.description;

	auto pos = d.range.start;

	if (s.startsWith("Line is longer than ") && s.endsWith(" characters"))
	{
		d.range = TextRange(Position(pos.line,
				s["Line is longer than ".length .. $ - " characters".length].to!uint),
				Position(pos.line, 1000));
	}
	else if (s.startsWith("Expected `"))
	{
		s = s["Expected ".length .. $];
		if (s.startsWith("`;`"))
		{
			const bytes = document.positionToBytes(pos);
			scope const text = document.rawText;

			// span after last word
			size_t issueStart;
			bool first = true;
			foreach_reverse (i, dchar c; text[0 .. bytes])
			{
				if (c == ';')
				{
					// this ain't right, expected semicolon issue but
					// semicolon is the first thing before this token
					// happens when syntax before is broken, let's discard!
					// for example in `foo.foreach(a;b)`
					return false;
				}
				if (!isDIdentifierSeparatingChar(c))
					break;
				issueStart = i;
			}

			auto startPos = document.movePositionBytes(pos, bytes, issueStart);
			size_t issueEnd = issueStart;

			// span until newline or next word character
			first = true;
			foreach (i, dchar c; text[issueStart .. $])
			{
				issueEnd = issueStart + i;
				if (first)
				{
					if (c.among!('\r', '\n'))
						break;

					if (!isDIdentifierSeparatingChar(c))
						first = false;
				}
				else
				{
					if (isDIdentifierSeparatingChar(c))
						break;
				}
			}
			auto endPos = document.movePositionBytes(startPos, issueStart, issueEnd);

			d.range = TextRange(startPos, endPos);
		}
		else
		{
			const bytes = document.positionToBytes(pos);
			scope const text = document.rawText;
			size_t issueStart = bytes;
			size_t issueEnd = bytes;

			// span from start of last word
			bool first = true;
			foreach_reverse (i, dchar c; text[0 .. issueStart])
			{
				if (first)
				{
					if (!isDIdentifierSeparatingChar(c))
						first = false;
				}
				else
				{
					if (isDIdentifierSeparatingChar(c))
						break;
				}
				issueStart = i;
			}

			// span to end of next word
			first = true;
			foreach (i, dchar c; text[bytes .. $])
			{
				issueEnd = bytes + i;
				if (first)
				{
					if (!isDIdentifierSeparatingChar(c))
						first = false;
				}
				else
				{
					if (isDIdentifierSeparatingChar(c))
						break;
				}
			}

			d.range = TextRange(
				document.movePositionBytes(pos, bytes, issueStart),
				document.movePositionBytes(pos, bytes, issueEnd)
			);
		}
	}
	else
	{
		const range = document.lineByteRangeAt(pos.line);
		scope const line = document.rawText[range[0] .. range[1]];
		auto chars = wordInLine(line, pos.character);

		if (line[chars[0] .. chars[1]] == "auto")
		{
			// syntax error on the word "auto"
			// check for foreach (auto key; value)

			auto leading = line[0 .. chars[0]].stripRight;
			if (leading.endsWith("("))
			{
				leading = leading[0 .. $ - 1].stripRight;
				if (leading.endsWith("foreach", "foreach_reverse"))
				{
					// this is foreach (auto
					d.source = SyntaxHintDiagnosticSource;
					d.message = "foreach (auto key; value) is not valid D "
						~ "syntax. Use foreach (key; value) instead.";
					d.code = JSONValue("served.foreach-auto").opt;
					// range is used in code_actions to remove auto
					d.range = TextRange(pos.line, chars[0], pos.line, chars[1]);
					return true;
				}
			}
		}

		d.range = TextRange(pos.line, chars[0], pos.line, chars[1]);
	}
	return true;
}

// adjusts error location of
// import |std.stdio;
// to
// ~import std.stdio;~
private bool adjustRangeForLocalImportsError(ref Diagnostic d,
	Document document, DScannerIssue issue)
{
	const bytes = document.positionToBytes(d.range.start);
	scope const text = document.rawText;

	const start = text[0 .. bytes].lastIndexOf("import");
	if (start == -1)
		return false;
	const end = text[bytes .. $].indexOf(";");
	if (end == -1)
		return false;

	const startPos = document.movePositionBytes(d.range.start, bytes, start);
	const endPos = document.movePositionBytes(d.range.start, bytes, bytes + end + 1);

	d.range = TextRange(startPos, endPos);
	return true;
}

void adjustSeverityForType(ref Diagnostic d, Document, DScannerIssue issue)
{
	if (issue.key == "dscanner.suspicious.unused_parameter"
			|| issue.key == "dscanner.suspicious.unused_variable")
	{
		d.severity = DiagnosticSeverity.hint;
		d.tags = opt([DiagnosticTag.unnecessary]);
	}
	else
	{
		d.severity = issue.type == "error" ? DiagnosticSeverity.error : DiagnosticSeverity
			.warning;
	}
}

version (unittest)
{
	import dscanner.analysis.config : defaultStaticAnalysisConfig;
	import inifiled : writeINIFile;
	import std.array : array;
	import std.file : tempDir, write;
	import std.path : buildPath;
	import std.range : enumerate;
	import unit_threaded.assertions;

	private class DiagnosticTester
	{
		WorkspaceD backend;
		DscannerComponent dscanner;
		string dscannerIni;

		DScannerIssue[] issues;
		Diagnostic[] diagnostics;

		this(string id)
		{
			backend = new WorkspaceD();
			// use instance-less
			dscanner = new DscannerComponent();
			dscanner.workspaced = backend;

			auto config = defaultStaticAnalysisConfig;
			foreach (ref value; config.tupleof)
				static if (is(typeof(value) == string))
					value = "enabled";

			dscannerIni = buildPath(tempDir(), id ~ "-dscanner.ini");
			writeINIFile(config, dscannerIni);
		}

		DScannerIssue[] lint(scope const(char)[] code)
		{
			return dscanner.lint("", dscannerIni, code, false,
				servedDefaultDscannerConfig).getBlocking();
		}

		auto diagnosticsAt(Position location)
		{
			return diagnostics.enumerate.filter!(a
				=> a.value.range.contains(location));
		}

		Diagnostic[] diagnosticsAt(Position location, string key)
		{
			return diagnostics
				.filter!(a
					=> a.range.contains(location)
					&& a.code.get.type == JSONType.string
					&& a.code.get.str == key)
				.array;
		}

		Diagnostic[] syntaxErrorsAt(Position location)
		{
			return diagnosticsAt(location).filter!(a => !issues[a.index].key.length)
				.map!"a.value"
				.array;
		}

		void build(Document document)
		{
			issues = lint(document.rawText);

			diagnostics = null;
			foreach (issue; issues)
			{
				Diagnostic d;
				if (!d.adjustRangeForType(document, issue))
					continue;
				d.adjustSeverityForType(document, issue);

				if (!d.source.isNull && d.source.get.length)
				{
					// handled by previous functions
					diagnostics ~= d;
					continue;
				}

				d.code = JSONValue(issue.key).opt;
				d.message = issue.description;
				diagnostics ~= d;
			}
		}
	}
}

unittest
{
	DiagnosticTester test = new DiagnosticTester("test-syntax-errors");

	Document document = Document.nullDocument(q{
void main()
{
	if x == 4 {
	}
}
});

	test.build(document);
	shouldEqual(test.syntaxErrorsAt(Position(0, 0)).length, 0);
	shouldEqual(test.syntaxErrorsAt(Position(3, 4)).length, 1);
	shouldEqual(test.syntaxErrorsAt(Position(3, 4))[0].message, "Expected `(` instead of `x`");
	shouldEqual(test.syntaxErrorsAt(Position(3, 4))[0].range, TextRange(3, 1, 3, 5));

	document = Document.nullDocument(q{
void main()
{
	foo()
}
});

	test.build(document);
	shouldEqual(test.syntaxErrorsAt(Position(0, 0)).length, 0);
	shouldEqual(test.syntaxErrorsAt(Position(3, 3)).length, 0);
	shouldEqual(test.syntaxErrorsAt(Position(3, 4)).length, 1);
	shouldEqual(test.syntaxErrorsAt(Position(3, 4))[0].message, "Expected `;` instead of `}`");
	shouldEqual(test.syntaxErrorsAt(Position(3, 4))[0].range, TextRange(3, 4, 3, 6));

	document = Document.nullDocument(q{
void main()
{
	foo(hello)  {}
}
});

	test.build(document);
	shouldEqual(test.syntaxErrorsAt(Position(3, 3)).length, 0);
	shouldEqual(test.syntaxErrorsAt(Position(3, 3)).length, 0);
	shouldEqual(test.syntaxErrorsAt(Position(3, 4)).length, 0);
	shouldEqual(test.syntaxErrorsAt(Position(3, 9)).length, 0);
	shouldEqual(test.syntaxErrorsAt(Position(3, 10)).length, 1);
	shouldEqual(test.syntaxErrorsAt(Position(3, 10))[0].message, "Expected `;` instead of `{`");
	shouldEqual(test.syntaxErrorsAt(Position(3, 10))[0].range, TextRange(3, 10, 3, 15));
}

unittest
{
	DiagnosticTester test = new DiagnosticTester("test-syntax-issues");

	Document document = Document.nullDocument(q{
void main()
{
	foreach (auto key; value)
	{
	}
}
});

	test.build(document);
	shouldEqual(test.diagnosticsAt(Position(0, 0), "served.foreach-auto").length, 0);
	auto diag = test.diagnosticsAt(Position(3, 11), "served.foreach-auto");
	shouldEqual(diag.length, 1);
	shouldEqual(diag[0].range, TextRange(3, 10, 3, 14));
}

unittest
{
	DiagnosticTester test = new DiagnosticTester("test-suspicious-local-imports");

	Document document = Document.nullDocument(q{
void main()
{
	import   imports.stdio;

	writeln("hello");
}
});

	test.build(document);
	shouldEqual(test.diagnosticsAt(Position(0, 0), LocalImportCheckKEY).length, 0);
	auto diag = test.diagnosticsAt(Position(3, 11), LocalImportCheckKEY);
	shouldEqual(diag.length, 1);
	shouldEqual(diag[0].range, TextRange(3, 1, 3, 24));
}
