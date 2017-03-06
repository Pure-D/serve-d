module served.linters.dscanner;

import std.conv;
import std.file;
import std.path;
import std.string;
import std.json;

import served.types;
import served.linters.diagnosticmanager;

import workspaced.api;
import workspaced.coms;

enum DiagnosticSlot = 0;

void lint(Document document)
{
	auto ini = buildPath(workspaceRoot, "dscanner.ini");
	if (!exists(ini))
		ini = "dscanner.ini";
	auto issues = syncYield!(dscanner.lint)(document.uri.uriToFile, ini);
	Diagnostic[] result;

	if (issues.type == JSON_TYPE.ARRAY)
	{
		foreach (issue; issues.array)
		{
			Diagnostic d;
			auto s = issue["description"].str;
			if (s.startsWith("Line is longer than ") && s.endsWith(" characters"))
				d.range = TextRange(Position(cast(uint) issue["line"].integer - 1,
						s["Line is longer than ".length .. $ - " characters".length].to!uint), Position(cast(uint) issue["line"].integer - 1, 1000));
			else
				d.range = TextRange(Position(cast(uint) issue["line"].integer - 1,
						cast(uint) issue["column"].integer - 1));
			d.severity = issue["type"].str == "warn" ? DiagnosticSeverity.warning
				: DiagnosticSeverity.error;
			d.source = "DScanner";
			d.message = issue["description"].str;
			result ~= d;
		}
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
 