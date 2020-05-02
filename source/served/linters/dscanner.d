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

static immutable string DScannerDiagnosticSource = "DScanner";

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
			ini, document.rawText).getYield;
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
				if (!isIdentifierSeparatingChar(c))
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

					if (!isIdentifierSeparatingChar(c))
						first = false;
				}
				else
				{
					if (isIdentifierSeparatingChar(c))
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
					if (!isIdentifierSeparatingChar(c))
						first = false;
				}
				else
				{
					if (isIdentifierSeparatingChar(c))
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
					if (!isIdentifierSeparatingChar(c))
						first = false;
				}
				else
				{
					if (isIdentifierSeparatingChar(c))
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
		d.range = document.wordRangeAt(pos);
	}
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

unittest
{
	import dscanner.analysis.config : defaultStaticAnalysisConfig;
	import inifiled : writeINIFile;
	import std.array : array;
	import std.file : tempDir, write;
	import std.path : buildPath;
	import std.range : enumerate;
	import unit_threaded.assertions; // @suppress(dscanner.suspicious.local_imports)

	auto backend = new WorkspaceD();
	// use instance-less
	DscannerComponent dscanner = new DscannerComponent();
	dscanner.workspaced = backend;

	auto config = defaultStaticAnalysisConfig;
	foreach (ref value; config.tupleof)
		static if (is(typeof(value) == string))
			value = "enabled";

	auto dscannerIni = buildPath(tempDir(), "dscanner.ini");
	writeINIFile(config, dscannerIni);

	DScannerIssue[] lint(scope const(char)[] code)
	{
		return dscanner.lint("", dscannerIni, code).getBlocking();
	}

	DScannerIssue[] issues;
	Diagnostic[] diagnostics;

	auto diagnosticsAt(Position location)
	{
		return diagnostics.enumerate.filter!(a => a.value.range.contains(location));
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
			d.adjustRangeForType(document, issue);
			d.adjustSeverityForType(document, issue);
			d.message = issue.description;
			diagnostics ~= d;
		}
	}

	Document document = Document.nullDocument(q{
void main()
{
	if x == 4 {
	}
}
});

	build(document);
	shouldEqual(syntaxErrorsAt(Position(0, 0)).length, 0);
	shouldEqual(syntaxErrorsAt(Position(3, 4)).length, 1);
	shouldEqual(syntaxErrorsAt(Position(3, 4))[0].message, "Expected `(` instead of `x`");
	shouldEqual(syntaxErrorsAt(Position(3, 4))[0].range, TextRange(3, 1, 3, 5));

	document = Document.nullDocument(q{
void main()
{
	foo()
}
});

	build(document);
	shouldEqual(syntaxErrorsAt(Position(0, 0)).length, 0);
	shouldEqual(syntaxErrorsAt(Position(3, 3)).length, 0);
	shouldEqual(syntaxErrorsAt(Position(3, 4)).length, 1);
	shouldEqual(syntaxErrorsAt(Position(3, 4))[0].message, "Expected `;` instead of `}`");
	shouldEqual(syntaxErrorsAt(Position(3, 4))[0].range, TextRange(3, 4, 3, 6));

	document = Document.nullDocument(q{
void main()
{
	foo(hello)  {}
}
});

	build(document);
	shouldEqual(syntaxErrorsAt(Position(3, 3)).length, 0);
	shouldEqual(syntaxErrorsAt(Position(3, 3)).length, 0);
	shouldEqual(syntaxErrorsAt(Position(3, 4)).length, 0);
	shouldEqual(syntaxErrorsAt(Position(3, 9)).length, 0);
	shouldEqual(syntaxErrorsAt(Position(3, 10)).length, 1);
	shouldEqual(syntaxErrorsAt(Position(3, 10))[0].message, "Expected `;` instead of `{`");
	shouldEqual(syntaxErrorsAt(Position(3, 10))[0].range, TextRange(3, 10, 3, 15));
}
