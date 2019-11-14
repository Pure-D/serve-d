module served.linters.dub;

import core.thread;

import painlessjson;

import served.extension;
import served.linters.diagnosticmanager;
import served.types;

import std.algorithm;
import std.array;
import std.datetime.stopwatch : StopWatch;
import std.experimental.logger;
import std.file;
import std.json;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;

import workspaced.api;
import workspaced.coms;

import workspaced.com.dub : BuildIssue, ErrorType;

enum DiagnosticSlot = 1;

enum DubDiagnosticSource = "DUB";

string fixPath(string cwd, string workspaceRoot, string path, string[] stringImportPaths)
{
	auto mixinIndex = path.indexOf("-mixin-");
	if (mixinIndex != -1)
		path = path[0 .. mixinIndex];

	// the dub API uses getcwd by default for the build folder
	auto absPath = isAbsolute(path) ? path : buildNormalizedPath(cwd, path);

	// but just in case it changes, let's add a fallback to the workspaceRoot (which is the dub path)...
	if (!exists(absPath))
		absPath = buildNormalizedPath(workspaceRoot, path);

	// .d files are always emitted by the compiler, just use them
	if (path.endsWith(".d"))
		path = absPath;
	else if (!isAbsolute(path))
	{
		// this is the fallback code for .dt files or other custom error locations thrown by libraries
		// with pragma messages
		bool found;
		foreach (imp; chain([cwd, workspaceRoot], stringImportPaths))
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

bool dubLintRunning, retryDubAtEnd;
Duration lastDubDuration;
int currentBuildToken;

void lint(Document document)
{
	auto instance = activeInstance = backend.getBestInstance!DubComponent(document.uri.uriToFile);
	if (!instance)
		return;

	auto fileConfig = config(document.uri);
	if (!fileConfig.d.enableLinting || !fileConfig.d.enableDubLinting)
		return;

	if (dubLintRunning)
	{
		retryDubAtEnd = true;
		return;
	}

	dubLintRunning = true;
	scope (exit)
		dubLintRunning = false;

	while (true)
	{
		stderr.writeln("Running dub build");
		currentBuildToken++;
		int startToken = currentBuildToken;
		setTimeout({
			// dub build taking much longer now, we probably succeeded compiling where we failed last time so erase diagnostics
			if (dubLintRunning && startToken == currentBuildToken)
			{
				diagnostics[DiagnosticSlot] = null;
				updateDiagnostics();
			}
		}, lastDubDuration + 100.msecs);
		StopWatch sw;
		sw.start();
		auto imports = instance.get!DubComponent.stringImports;
		auto issues = instance.get!DubComponent.build.getYield;
		sw.stop();
		lastDubDuration = sw.peek;
		trace("dub build finished in ", sw.peek, " with ", issues.length, " issues");
		trace(issues);
		auto result = appender!(PublishDiagnosticsParams[]);

		void pushError(Diagnostic error, string uri)
		{
			bool found;
			foreach (ref elem; result.data)
				if (elem.uri == uri)
				{
					found = true;
					elem.diagnostics ~= error;
				}
			if (!found)
				result ~= PublishDiagnosticsParams(uri, [error]);
		}

		while (!issues.empty)
		{
			auto issue = issues.front;
			issues.popFront();
			int numSupplemental = cast(int) issues.length;
			foreach (i, other; issues)
				if (!other.cont)
				{
					numSupplemental = cast(int) i;
					break;
				}
			auto supplemental = issues[0 .. numSupplemental];
			if (numSupplemental > 0)
				issues = issues[numSupplemental .. $];

			auto uri = uriFromFile(fixPath(getcwd(),
					instance.get!DubComponent.path.toString, issue.file, imports));

			Diagnostic error;
			error.range = TextRange(issue.line - 1, issue.column - 1, issue.line - 1, issue.column);
			error.severity = mapDubLintType(issue.type);
			if (issue.type == ErrorType.Deprecation)
				error.tags = opt([DiagnosticTag.deprecated_]);
			error.source = DubDiagnosticSource;
			error.message = issue.text;
			if (supplemental.length)
				error.relatedInformation = opt(supplemental.map!((other) {
						DiagnosticRelatedInformation related;
						string otherUri = other.file != issue.file ? uriFromFile(fixPath(getcwd(),
						instance.get!DubComponent.path.toString, other.file, imports)) : uri;
						related.location = Location(otherUri, TextRange(other.line - 1,
						other.column - 1, other.line - 1, other.column));
						extendErrorRange(related.location.range, otherUri);
						related.message = other.text;
						return related;
					}).array);

			extendErrorRange(error.range, uri);
			pushError(error, uri);

			foreach (i, suppl; supplemental)
			{
				if (suppl.text.startsWith("instantiated from here:"))
				{
					// add all "instantiated from here" errors in the project as diagnostics

					auto supplUri = issue.file != suppl.file ? uriFromFile(fixPath(getcwd(),
							instance.get!DubComponent.path.toString, suppl.file, imports)) : uri;

					if (workspaceIndex(supplUri) == size_t.max)
						continue;

					Diagnostic supplError;
					supplError.range = TextRange(Position(suppl.line - 1, suppl.column - 1));
					supplError.severity = DiagnosticSeverity.error;
					supplError.source = DubDiagnosticSource;
					supplError.message = issue.text ~ "\n" ~ suppl.text;
					if (i + 1 < supplemental.length)
						supplError.relatedInformation = opt(error.relatedInformation.get[i + 1 .. $]);
					extendErrorRange(supplError.range, supplUri);
					pushError(supplError, supplUri);
				}
			}
		}

		diagnostics[DiagnosticSlot] = result.data;
		updateDiagnostics();

		if (!retryDubAtEnd)
			break;
		else
			retryDubAtEnd = false;
	}
}

void extendErrorRange(ref TextRange range, string uri)
{
	auto doc = documents.tryGet(uri);
	if (!doc.rawText.length)
		return;

	range = doc.wordRangeAt(range.start);
}

void clear()
{
	diagnostics[DiagnosticSlot] = null;
	updateDiagnostics();
}
