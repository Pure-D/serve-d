module served.linters.dub;

import core.thread;

import painlessjson;

import served.extension;
import served.linters.diagnosticmanager;
import served.types;

import std.algorithm;
import std.array;
import std.file;
import std.json;
import std.path;
import std.process;
import std.stdio;
import std.string;

import workspaced.api;
import workspaced.coms;

import workspaced.com.dub : ErrorType;

enum DiagnosticSlot = 1;

enum DubDiagnosticSource = "DUB";

string fixPath(string workspaceRoot, string path, string[] stringImportPaths)
{
	auto mixinIndex = path.indexOf("-mixin-");
	if (mixinIndex != -1)
		path = path[0 .. mixinIndex];
	auto absPath = isAbsolute(path) ? path : buildNormalizedPath(workspaceRoot, path);
	if (path.endsWith(".d"))
		path = absPath;
	else if (!isAbsolute(path))
	{
		bool found;
		foreach (imp; stringImportPaths)
		{
			if (!isAbsolute(imp))
				imp = buildNormalizedPath(workspaceRoot, imp);
			auto modPath = buildNormalizedPath(imp, path);
			if (exists(modPath))
			{
				path = modPath;
				found = true;
				break;
			}
		}
		if (!found)
			path = absPath;
	}
	else
		path = absPath;
	return path;
}

DiagnosticSeverity mapDubLintType(ErrorType type)
{
	final switch (type)
	{
	case ErrorType.Deprecation:
		return DiagnosticSeverity.information;
	case ErrorType.Warning:
		return DiagnosticSeverity.warning;
	case ErrorType.Error:
		return DiagnosticSeverity.error;
	}
}

void lint(Document document)
{
	auto workspaceRoot = workspaceRootFor(document.uri);

	auto fileConfig = config(document.uri);
	if (!fileConfig.d.enableLinting || !fileConfig.d.enableDubLinting)
		return;

	stderr.writeln("Running dub build");
	auto imports = backend.get!DubComponent(workspaceRoot).stringImports;
	auto issues = backend.get!DubComponent(workspaceRoot).build.getYield;
	PublishDiagnosticsParams[] result;
	foreach (issue; issues)
	{
		auto uri = uriFromFile(fixPath(workspaceRoot, issue.file, imports));
		Diagnostic error;
		error.range = TextRange(Position(issue.line - 1, issue.column - 1));
		error.severity = mapDubLintType(issue.type);
		error.source = DubDiagnosticSource;
		error.message = issue.text;
		bool found;
		foreach (ref elem; result)
			if (elem.uri == uri)
			{
				found = true;
				elem.diagnostics ~= error;
			}
		if (!found)
			result ~= PublishDiagnosticsParams(uri, [error]);
	}

	diagnostics[DiagnosticSlot] = result;
	updateDiagnostics(document.uri);
}

void clear()
{
	diagnostics[DiagnosticSlot] = null;
	updateDiagnostics();
}
