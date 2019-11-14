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

	auto ini = buildPath(instance.cwd, "dscanner.ini");
	if (!exists(ini))
		ini = "dscanner.ini";
	auto issues = instance.get!DscannerComponent.lint(document.uri.uriToFile,
			ini, document.rawText).getYield;
	Diagnostic[] result;

	foreach (issue; issues)
	{
		if (ignoredKeys.canFind(issue.key))
			continue;
		Diagnostic d;
		auto s = issue.description;
		auto text = document.lineAt(cast(uint) issue.line - 1).stripRight;
		string keyNormalized = issue.key.startsWith("dscanner.")
			? issue.key["dscanner.".length .. $] : issue.key;
		if (text.canFind("@suppress(all)", "@suppress:all", "@suppress(" ~ issue.key ~ ")",
				"@suppress:" ~ issue.key, "@suppress(" ~ keyNormalized ~ ")", "@suppress:" ~ keyNormalized)
				|| text.endsWith("stfu"))
			continue;
		if (s.startsWith("Line is longer than ") && s.endsWith(" characters"))
			d.range = TextRange(Position(cast(uint) issue.line - 1,
					s["Line is longer than ".length .. $ - " characters".length].to!uint),
					Position(cast(uint) issue.line - 1, 1000));
		else
			d.range = document.wordRangeAt(Position(cast(uint) issue.line - 1, cast(uint) issue.column - 1));

		if (issue.key == "dscanner.suspicious.unused_parameter"
				|| issue.key == "dscanner.suspicious.unused_variable")
		{
			d.severity = DiagnosticSeverity.hint;
			d.tags = opt([DiagnosticTag.unnecessary]);
		}
		else
		{
			d.severity = issue.type ? DiagnosticSeverity.warning : DiagnosticSeverity.error;
		}
		d.source = DScannerDiagnosticSource;
		d.message = issue.description;
		d.code = JSONValue(issue.key);
		result ~= d;
	}

	foreach (ref existing; diagnostics[DiagnosticSlot])
		if (existing.uri == document.uri)
		{
			existing.diagnostics = result;
			updateDiagnostics(document.uri);
			return;
		}
	diagnostics[DiagnosticSlot] ~= PublishDiagnosticsParams(document.uri, result);
	updateDiagnostics(document.uri);
}

void clear()
{
	diagnostics[DiagnosticSlot] = null;
	updateDiagnostics();
}
