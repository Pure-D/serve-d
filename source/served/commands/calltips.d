module served.commands.calltips;

import served.ddoc;
import served.extension;
import served.types;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.coms;

import std.algorithm : max;

/**
 * Convert DCD calltips to LSP compatible `SignatureHelp` objects
 * Params:
 *      calltips = Ddoc strings for each available calltip
 *      symbols = array of possible signatures as DCD symbols
 *      textTilCursor = The entire contents of the file being edited up
 *                      until the cursor
 */
SignatureHelp convertDCDCalltips(string[] calltips,
		DCDCompletions.Symbol[] symbols, string textTilCursor)
{
	SignatureInformation[] signatures;
	int[] paramsCounts; // Number of params for each calltip
	SignatureHelp help;
	foreach (i, calltip; calltips)
	{
		auto sig = SignatureInformation(calltip);
		immutable DCDCompletions.Symbol symbol = symbols[i];
		if (symbol.documentation.length)
			sig.documentation = MarkupContent(symbol.documentation.ddocToMarked);
		auto funcParams = calltip.extractFunctionParameters;

		paramsCounts ~= cast(int) funcParams.length - 1;
		foreach (param; funcParams)
			sig.parameters ~= ParameterInformation(param);

		help.signatures ~= sig;
	}
	auto extractedParams = textTilCursor.extractFunctionParameters(true);
	size_t[] possibleFunctions;
	foreach (i, count; paramsCounts)
		if (count >= cast(int) extractedParams.length - 1)
			possibleFunctions ~= i;

	help.activeSignature = possibleFunctions.length ? cast(int) possibleFunctions[0] : 0;
	return help;
}

@protocolMethod("textDocument/signatureHelp")
SignatureHelp provideSignatureHelp(TextDocumentPositionParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	if (document.languageId == "d")
		return provideDSignatureHelp(params, workspaceRoot, document);
	else if (document.languageId == "diet")
		return provideDietSignatureHelp(params, workspaceRoot, document);
	else
		return SignatureHelp.init;
}

SignatureHelp provideDSignatureHelp(TextDocumentPositionParams params,
		string workspaceRoot, ref Document document)
{
	if (!backend.has!DCDComponent(workspaceRoot))
		return SignatureHelp.init;

	auto currOffset = cast(int) document.positionToBytes(params.position);

	// Show call tip if open bracket is on same line and and not followed by
	// close bracket. Not as reliable as AST parsing but much faster and should
	// work for 90%+ of cases.
	import std.algorithm : countUntil;
	import std.range: retro;
	auto openBracketOffset = document.text[0..currOffset].retro().countUntil("(");
	auto closeBracketOffset = document.text[0..currOffset].retro().countUntil(")");
	auto nlBracketOffset = document.text[0..currOffset].retro().countUntil("\n");
	if (openBracketOffset >= 0 && openBracketOffset < closeBracketOffset
			&& openBracketOffset < nlBracketOffset) {
		currOffset -= openBracketOffset;
	}

	DCDCompletions result = backend.get!DCDComponent(workspaceRoot)
		.listCompletion(document.text, currOffset).getYield;
	switch (result.type)
	{
	case DCDCompletions.Type.calltips:
		return convertDCDCalltips(result.calltips,
				result.symbols, document.text[0 .. currOffset]);
	case DCDCompletions.Type.identifiers:
		return SignatureHelp.init;
	default:
		throw new Exception("Unexpected result from DCD");
	}
}

SignatureHelp provideDietSignatureHelp(TextDocumentPositionParams params,
		string workspaceRoot, ref Document document)
{
	import served.diet;
	import dc = dietc.complete;

	auto completion = updateDietFile(document.uri.uriToFile, workspaceRoot, document.text);

	size_t offset = document.positionToBytes(params.position);
	auto raw = completion.completeAt(offset);
	CompletionItem[] ret;

	if (raw is dc.Completion.completeD)
	{
		string code;
		dc.extractD(completion, offset, code, offset);
		if (offset <= code.length && backend.has!DCDComponent(workspaceRoot))
		{
			auto dcd = backend.get!DCDComponent(workspaceRoot).listCompletion(code,
					cast(int) offset).getYield;
			if (dcd.type == DCDCompletions.Type.calltips)
				return convertDCDCalltips(dcd.calltips, dcd.symbols, code[0 .. offset]);
		}
	}
	return SignatureHelp.init;
}
