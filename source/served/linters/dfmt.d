module served.linters.dfmt;

import std.algorithm;
import std.array;
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

import workspaced.com.dfmt;

static immutable string DfmtDiagnosticSource = "dfmt";

enum DiagnosticSlot = 2;

void lint(Document document)
{
	auto fileConfig = config(document.uri);
	if (!fileConfig.d.enableFormatting)
		return;

	if (!backend.has!DfmtComponent)
		return;
	auto dfmt = backend.get!DfmtComponent;

	createDiagnosticsFor!DiagnosticSlot(document.uri) = lintDfmt(dfmt, document);
	updateDiagnostics(document.uri);
}

private Diagnostic[] lintDfmt(DfmtComponent dfmt, ref Document document)
{
	auto instructions = dfmt.findDfmtInstructions(document.rawText);

	auto diagnostics = appender!(Diagnostic[]);
	bool fmtOn = true;

	Position positionCache;
	size_t byteCache;

	void setFmt(DfmtInstruction instruction, bool on)
	{
		if (fmtOn == on)
		{
		}
		fmtOn = on;
	}

	foreach (DfmtInstruction instruction; instructions)
	{
		Diagnostic d;
		d.source = DfmtDiagnosticSource;
		auto start = document.movePositionBytes(positionCache, byteCache, instruction.index);
		auto end = document.movePositionBytes(start, instruction.index, instruction.index + instruction.length);
		positionCache = end;
		byteCache = instruction.index + instruction.length;
		d.range = TextRange(start, end);

		final switch (instruction.type)
		{
			case DfmtInstruction.Type.dfmtOn:
			case DfmtInstruction.Type.dfmtOff:
				bool on = instruction.type == DfmtInstruction.Type.dfmtOn;
				if (on == fmtOn)
				{
					d.message = on ? "Redundant `dfmt on`" : "Redundant `dfmt off`";
					d.code = JSONValue(on ? "redundant-on" : "redundant-off");
					d.severity = DiagnosticSeverity.hint;
					d.tags = [DiagnosticTag.unnecessary];
					diagnostics ~= d;
				}
				fmtOn = on;
				break;
			case DfmtInstruction.Type.unknown:
				d.message = "Not a valid dfmt command (try `//dfmt off` or `//dfmt on` instead)";
				d.code = "unknown-comment";
				d.severity = DiagnosticSeverity.warning;
				diagnostics ~= d;
				break;
		}
	}

	return diagnostics.data;
}

void clear()
{
	diagnostics[DiagnosticSlot] = null;
	updateDiagnostics();
}

@("misspelling on/off")
unittest
{
	auto dfmt = new DfmtComponent();
	dfmt.workspaced = new WorkspaceD();
	Document d = Document.nullDocument(`void foo() {
	//dfmt offs
	int i = 5;
	//dfmt onf
}`);
	auto linted = lintDfmt(dfmt, d);
	assert(linted.length == 2);
	assert(linted[0].severity.get == DiagnosticSeverity.warning);
	assert(linted[1].severity.get == DiagnosticSeverity.warning);
}

@("redundant on/off")
unittest
{
	auto dfmt = new DfmtComponent();
	dfmt.workspaced = new WorkspaceD();
	Document d = Document.nullDocument(`void foo() {
	//dfmt on
	//dfmt off
	int i = 5;
	//dfmt off
	//dfmt ons
}`);
	auto linted = lintDfmt(dfmt, d);
	import std.stdio; stderr.writeln("diagnostics:\n", linted);
	assert(linted.length == 3);
	assert(linted[0].severity.get == DiagnosticSeverity.hint);
	assert(linted[1].severity.get == DiagnosticSeverity.hint);
	assert(linted[2].severity.get == DiagnosticSeverity.warning);
}
