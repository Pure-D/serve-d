module served.linters.dub;

import core.thread;

import served.extension;
import served.linters.diagnosticmanager;
import served.types;

import std.algorithm;
import std.array;
import std.datetime.stopwatch : StopWatch;
import std.experimental.logger;
import std.file;
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

void applyDubLintType(ref Diagnostic error, ErrorType type)
{
	error.severity = mapDubLintType(type);
	if (type == ErrorType.Deprecation)
		error.tags = opt([DiagnosticTag.deprecated_]);
}

bool dubLintRunning, retryDubAtEnd;
Duration lastDubDuration;
int currentBuildToken;

void lint(Document document)
{
	void noErrors()
	{
		diagnostics[DiagnosticSlot] = null;
		updateDiagnostics();
	}

	auto instance = activeInstance = backend.getBestInstance!DubComponent(document.uri.uriToFile);
	if (!instance)
		return noErrors();

	auto fileConfig = config(document.uri);
	if (!fileConfig.d.enableLinting || !fileConfig.d.enableDubLinting)
		return noErrors();

	if (dubLintRunning)
	{
		retryDubAtEnd = true;
		return;
	}

	dubLintRunning = true;
	scope (exit)
		dubLintRunning = false;

	do
	{
		retryDubAtEnd = false;

		if (!instance.get!DubComponent.isValidBuildConfiguration)
		{
			trace("Not running dub build lint in '", instance.cwd,
				"', because it's not a buildable package");
			return noErrors();
		}

		trace("Running dub build in ", instance.cwd);
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

		void pushError(Diagnostic error, DocumentUri uri)
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
			applyDubLintType(error, issue.type);
			error.source = DubDiagnosticSource;
			error.message = issue.text;
			if (supplemental.length)
				error.relatedInformation = opt(supplemental.map!((other) {
						DiagnosticRelatedInformation related;
						string otherUri = other.file != issue.file ? uriFromFile(fixPath(getcwd(),
						instance.get!DubComponent.path.toString, other.file, imports)) : uri;
						related.location = Location(otherUri, TextRange(other.line - 1,
						other.column - 1, other.line - 1, other.column));
						extendErrorRange(related.location.range, instance, otherUri);
						related.message = other.text;
						return related;
					}).array);

			extendErrorRange(error.range, instance, uri, error);
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
					applyDubLintType(supplError, issue.type);
					supplError.source = DubDiagnosticSource;
					supplError.message = issue.text ~ "\n" ~ suppl.text;
					if (i + 1 < supplemental.length)
						supplError.relatedInformation = opt(error.relatedInformation.deref[i + 1 .. $]);
					extendErrorRange(supplError.range, instance, supplUri, supplError);
					pushError(supplError, supplUri);
				}
			}
		}

		diagnostics[DiagnosticSlot] = result.data;
		updateDiagnostics();
	}
	while (retryDubAtEnd);
}

void extendErrorRange(ref TextRange range, WorkspaceD.Instance instance,
	DocumentUri uri, Diagnostic info = Diagnostic.init)
{
	auto doc = documents.tryGet(uri);
	if (!doc.rawText.length)
		return;

	if (info.message.length)
	{
		auto loc = doc.positionToBytes(range.start);
		auto result = instance.get!DubComponent.resolveDiagnosticRange(
				doc.rawText, cast(int)loc, info.message);
		if (result[0] != result[1])
		{
			auto start = doc.movePositionBytes(range.start, loc, result[0]);
			auto end = doc.movePositionBytes(start, result[0], result[1]);
			range = TextRange(start, end);
			return;
		}
	}

	range = doc.wordRangeAt(range.start);
}

void clear()
{
	diagnostics[DiagnosticSlot] = null;
	updateDiagnostics();
}
