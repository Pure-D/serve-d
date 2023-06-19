/// Linting module for ClangCompilationDatabase
///
/// This linter will simply run the command in the `compile_commands.json` file
/// and scan the output for errors.
module served.linters.ccdb;

import served.linters.diagnosticmanager;
import served.types;

import workspaced.api;
import workspaced.coms;

import std.algorithm;
import std.experimental.logger;
import std.file;
import std.process;
import std.range;

enum DiagnosticSlot = 3;
enum CcdbDiagnosticSource = "compile_commands.json";

private struct DocLinterStatus
{
	bool running;
	bool retryAtEnd;
}

DocLinterStatus[DocumentUri] linterStatus;

void lint(Document document)
{
	void removeForDoc()
	{
		auto diag = diagnostics[DiagnosticSlot];
		diag = diag.remove!(d => d.uri == document.uri);
		diagnostics[DiagnosticSlot] = diag;
	}

	void noErrors()
	{
		removeForDoc();
		updateDiagnostics();
	}

	auto instance = activeInstance = backend.getBestInstance!ClangCompilationDatabaseComponent(
		document.uri.uriToFile);
	if (!instance)
		return noErrors();

	auto fileConfig = config(document.uri);
	if (!fileConfig.d.enableLinting || !fileConfig.d.enableCcdbLinting)
		return noErrors();

	auto command = instance.get!ClangCompilationDatabaseComponent.getCompileCommand(
		uriToFile(document.uri));
	if (!command)
	{
		auto dbPath = instance.get!ClangCompilationDatabaseComponent.getDbPath();
		warningf("No command entry for %s in CCDB %s", uriToFile(document.uri), dbPath);
		return noErrors();
	}

	auto statusp = document.uri in linterStatus;
	if (!statusp)
	{
		linterStatus[document.uri] = DocLinterStatus();
		statusp = document.uri in linterStatus;
	}
	assert(statusp);

	if (statusp.running)
	{
		statusp.retryAtEnd = true;
		return;
	}

	statusp.running = true;
	scope (exit)
		statusp.running = false;

	removeForDoc();

	do
	{
		statusp.retryAtEnd = false;

		tracef("running CCDB command for %s", document.uri);
		auto issues = command.run().getYield();
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
			import served.linters.dub : applyDubLintType;

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

			auto uri = uriFromFile(command.getPath(issue.file));

			Diagnostic error;
			error.range = TextRange(issue.line - 1, issueColumn(issue.column), issue.line - 1, uint.max);
			applyDubLintType(error, issue.type);
			error.source = CcdbDiagnosticSource;
			error.message = issue.text;
			if (supplemental.length)
				error.relatedInformation = opt(supplemental.map!((other) {
						DiagnosticRelatedInformation related;
						string otherUri = other.file != issue.file ? command.getPath(
						other.file) : uri;
						related.location = Location(
							otherUri, TextRange(other.line - 1, issueColumn(other.column), other.line - 1, uint.max)
						);
						related.message = other.text;
						return related;
					}).array);

			//extendErrorRange(error.range, instance, uri, error);
			pushError(error, uri);

			foreach (i, suppl; supplemental)
			{
				if (suppl.text.startsWith("instantiated from here:"))
				{
					// add all "instantiated from here" errors in the project as diagnostics

					auto supplUri = issue.file != suppl.file ? uriFromFile(
						command.getPath(suppl.file)) : uri;

					if (workspaceIndex(supplUri) == size_t.max)
						continue;

					Diagnostic supplError;
					supplError.range = TextRange(
						suppl.line - 1, issueColumn(suppl.column), suppl.line - 1, uint.max
					);
					applyDubLintType(supplError, issue.type);
					supplError.source = CcdbDiagnosticSource;
					supplError.message = issue.text ~ "\n" ~ suppl.text;
					if (i + 1 < supplemental.length)
						supplError.relatedInformation = opt(
							error.relatedInformation.deref[i + 1 .. $]);
					pushError(supplError, supplUri);
				}
			}
		}

		removeForDoc();
		diagnostics[DiagnosticSlot] ~= result.data;
		updateDiagnostics();
	}
	while (statusp.retryAtEnd);
}

int issueColumn(const int column) pure
{
	return column > 0 ? column - 1 : 0;
}

void clear()
{
	diagnostics[DiagnosticSlot] = null;
	updateDiagnostics();
}
