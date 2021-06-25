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
			ini, document.rawText, false, servedDefaultDscannerConfig, true).getYield;
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

		if (issue.key.startsWith("workspaced"))
			d.source = SyntaxHintDiagnosticSource;
		else
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
	d.range = TextRange(
		document.lineColumnBytesToPosition(issue.range[0].line - 1, issue.range[0].column - 1),
		document.lineColumnBytesToPosition(issue.range[1].line - 1, issue.range[1].column - 1)
	);

	auto s = issue.description;
	if (s.startsWith("Line is longer than ") && s.endsWith(" characters"))
	{
		d.range.start.character = s["Line is longer than ".length .. $ - " characters".length].to!uint;
		d.range.end.character = 1000;
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

version (unittest)
{
	import dscanner.analysis.config : defaultStaticAnalysisConfig;
	import inifiled : writeINIFile;
	import std.array : array;
	import std.file : tempDir, write;
	import std.path : buildPath;
	import std.range : enumerate;

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

		~this()
		{
			shutdown(true);
		}

		void shutdown(bool dtor)
		{
			if (dscanner)
				dscanner.shutdown(dtor);
			dscanner = null;
			if (backend)
				backend.shutdown(dtor);
			backend = null;
		}

		DScannerIssue[] lint(scope const(char)[] code)
		{
			return dscanner.lint("", dscannerIni, code, false,
				servedDefaultDscannerConfig, true).getBlocking();
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
	scope (exit) test.shutdown(false);

	Document document = Document.nullDocument(q{
void main()
{
	if x == 4 {
	}
}
});

	test.build(document);
	assert(test.syntaxErrorsAt(Position(0, 0)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 4)).length == 1);
	assert(test.syntaxErrorsAt(Position(3, 4))[0].message == "Expected `(` instead of `x`");
	assert(test.syntaxErrorsAt(Position(3, 4))[0].range == TextRange(3, 1, 3, 5));

	document = Document.nullDocument(q{
void main()
{
	foo()
}
});

	test.build(document);
	assert(test.syntaxErrorsAt(Position(0, 0)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 3)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 4)).length == 1);
	assert(test.syntaxErrorsAt(Position(3, 4))[0].message == "Expected `;` instead of `}`");
	assert(test.syntaxErrorsAt(Position(3, 4))[0].range == TextRange(3, 4, 3, 6));

	document = Document.nullDocument(q{
void main()
{
	foo(hello)  {}
}
});

	test.build(document);
	assert(test.syntaxErrorsAt(Position(3, 3)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 3)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 4)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 9)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 10)).length == 1);
	assert(test.syntaxErrorsAt(Position(3, 10))[0].message == "Expected `;` instead of `{`");
	assert(test.syntaxErrorsAt(Position(3, 10))[0].range == TextRange(3, 10, 3, 15));

	document = Document.nullDocument(q{
void main()
{
	foo.foreach(a; b);
}
});

	test.build(document);
	assert(test.syntaxErrorsAt(Position(0, 0)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 4)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 5)).length == 1);
	assert(test.syntaxErrorsAt(Position(3, 5))[0].message == "Expected identifier instead of reserved keyword `foreach`");
	assert(test.syntaxErrorsAt(Position(3, 5))[0].range == TextRange(3, 5, 3, 12));

	document = Document.nullDocument(q{
void main()
{
	foo.
	foreach(a; b);
}
});

	test.build(document);
	// import std.stdio; stderr.writeln("diagnostics:\n", test.diagnostics);
	assert(test.syntaxErrorsAt(Position(0, 0)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 4)).length == 0);
	assert(test.syntaxErrorsAt(Position(3, 5)).length == 1);
	assert(test.syntaxErrorsAt(Position(3, 5))[0].message == "Expected identifier");
	assert(test.syntaxErrorsAt(Position(3, 5))[0].range == TextRange(3, 5, 4, 1));
}

unittest
{
	DiagnosticTester test = new DiagnosticTester("test-syntax-issues");
	scope (exit) test.shutdown(false);

	Document document = Document.nullDocument(q{
void main()
{
	foreach (auto key; value)
	{
	}
}
});

	test.build(document);
	assert(test.diagnosticsAt(Position(0, 0), "workspaced.foreach-auto").length == 0);
	auto diag = test.diagnosticsAt(Position(3, 11), "workspaced.foreach-auto");
	assert(diag.length == 1);
	assert(diag[0].range == TextRange(3, 10, 3, 14));
}

unittest
{
	DiagnosticTester test = new DiagnosticTester("test-syntax-issues");
	scope (exit) test.shutdown(false);

	Document document = Document.nullDocument(q{
void main()
{
	foreach (/* cool */ auto key; value)
	{
	}
}
});

	test.build(document);
	assert(test.diagnosticsAt(Position(0, 0), "workspaced.foreach-auto").length == 0);
	auto diag = test.diagnosticsAt(Position(3, 22), "workspaced.foreach-auto");
	assert(diag.length == 1);
	assert(diag[0].range == TextRange(3, 21, 3, 25));
}

unittest
{
	DiagnosticTester test = new DiagnosticTester("test-suspicious-local-imports");
	scope (exit) test.shutdown(false);

	Document document = Document.nullDocument(q{
void main()
{
	import   imports.stdio;

	writeln("hello");
}
});

	test.build(document);
	assert(test.diagnosticsAt(Position(0, 0), LocalImportCheckKEY).length == 0);
	auto diag = test.diagnosticsAt(Position(3, 11), LocalImportCheckKEY);
	assert(diag.length == 1);
	assert(diag[0].range == TextRange(3, 1, 3, 24));
}
