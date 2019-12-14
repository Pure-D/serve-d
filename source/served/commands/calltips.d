module served.commands.calltips;

import served.extension;
import served.types;
import served.utils.ddoc;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.com.dcdext;
import workspaced.coms;

import std.algorithm : max;
import std.string : strip, stripRight;
import std.json;

/**
 * Convert DCD calltips to LSP compatible `SignatureHelp` objects
 * Params:
 *      calltips = Ddoc strings for each available calltip
 *      symbols = array of possible signatures as DCD symbols
 *      textTilCursor = The entire contents of the file being edited up
 *                      until the cursor
 */
SignatureHelp convertDCDCalltips(DCDExtComponent dcdext, string[] calltips,
		DCDCompletions.Symbol[] symbols, CalltipsSupport extractedParams)
{
	SignatureInformation[] signatures;
	int[] paramsCounts; // Number of params for each calltip
	SignatureHelp help;

	foreach (i, calltip; calltips)
	{
		if (!calltip.length)
			continue;

		auto sig = SignatureInformation(calltip);
		immutable DCDCompletions.Symbol symbol = symbols[i];
		const docs = parseDdoc(symbol.documentation);
		if (docs != Comment.init)
			sig.documentation = MarkupContent(docs.ddocToMarked);
		else if (symbol.documentation.length)
			sig.documentation = MarkupContent(symbol.documentation);

		CalltipsSupport funcParams = dcdext.extractCallParameters(calltip,
				cast(int) calltip.length - 1, true);
		if (funcParams != CalltipsSupport.init)
		{
			if (extractedParams.inTemplateParameters && !funcParams.hasTemplate)
				continue;

			auto args = extractedParams.inTemplateParameters
				? funcParams.templateArgs : funcParams.functionArgs;
			if (args.length && args[$ - 1].variadic)
				paramsCounts ~= int.max;
			else
				paramsCounts ~= cast(int) args.length;

			ParameterInformation[] retParams;
			foreach (param; args)
			{
				int[2] range = param.nameRange[1] == 0 ? param.contentRange : param.nameRange;
				string paramName = calltip[range[0] .. range[1]];
				JSONValue paramLabel;
				if (capabilities.textDocument.signatureHelp.supportsLabelOffset)
					paramLabel = JSONValue([
							JSONValue(cast(int) calltip[0 .. param.contentRange[0]].countUTF16Length),
							JSONValue(cast(int) calltip[0 .. param.contentRange[1]].countUTF16Length)
							]);
				else
					paramLabel = JSONValue(calltip[param.contentRange[0] .. param.contentRange[1]]);
				Optional!MarkupContent paramDocs;
				if (docs != Comment.init)
				{
					auto docString = getParamDocumentation(docs, paramName);
					if (docString.length)
					{
						Optional!(string[]) formats = capabilities.textDocument
							.signatureHelp.signatureInformation.documentationFormat;
						MarkupKind kind = formats.isNull || formats.length == 0
							? MarkupKind.markdown : cast(MarkupKind) formats[0];
						string prefix = kind == MarkupKind.markdown ? "**" ~ paramName ~ "**: " : paramName
							~ ": ";
						string docRet = kind == MarkupKind.markdown
							? ddocToMarkdown(docString.strip) : docString.strip;
						paramDocs = MarkupContent(kind, (prefix ~ docRet).stripRight).opt;
					}
				}
				retParams ~= ParameterInformation(paramLabel, paramDocs);
			}

			sig.parameters = retParams.opt;
		}

		help.signatures ~= sig;
	}

	int writtenParamsCount = cast(int)(extractedParams.inTemplateParameters
			? extractedParams.templateArgs.length : extractedParams.functionArgs.length);

	size_t[] possibleFunctions;
	foreach (i, count; paramsCounts)
		if (count >= writtenParamsCount)
			possibleFunctions ~= i;

	if (extractedParams.activeParameter != -1)
		help.activeParameter = extractedParams.activeParameter.opt;

	help.activeSignature = possibleFunctions.length ? cast(int) possibleFunctions[0] : 0;

	return help;
}

@protocolMethod("textDocument/signatureHelp")
SignatureHelp provideSignatureHelp(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	string file = document.uri.uriToFile;
	if (document.languageId == "d")
		return provideDSignatureHelp(params, file, document);
	else if (document.languageId == "diet")
		return provideDietSignatureHelp(params, file, document);
	else
		return SignatureHelp.init;
}

SignatureHelp provideDSignatureHelp(TextDocumentPositionParams params,
		string file, ref Document document)
{
	if (!backend.hasBest!DCDComponent(file) || !backend.hasBest!DCDExtComponent(file))
		return SignatureHelp.init;

	auto currOffset = cast(int) document.positionToBytes(params.position);

	scope codeText = document.rawText.idup;

	DCDExtComponent dcdext = backend.best!DCDExtComponent(file);
	auto callParams = dcdext.extractCallParameters(codeText, cast(int) currOffset);
	if (callParams == CalltipsSupport.init)
		return SignatureHelp.init;

	DCDCompletions result = backend.best!DCDComponent(file)
		.listCompletion(codeText, callParams.functionParensRange[0] + 1).getYield;
	switch (result.type)
	{
	case DCDCompletions.Type.calltips:
		return convertDCDCalltips(dcdext,
				result.calltips, result.symbols, callParams);
	case DCDCompletions.Type.identifiers:
		return SignatureHelp.init;
	default:
		throw new Exception("Unexpected result from DCD");
	}
}

SignatureHelp provideDietSignatureHelp(TextDocumentPositionParams params,
		string file, ref Document document)
{
	import served.utils.diet;
	import dc = dietc.complete;

	auto completion = updateDietFile(file, document.rawText.idup);

	size_t offset = document.positionToBytes(params.position);
	auto raw = completion.completeAt(offset);
	CompletionItem[] ret;

	if (raw is dc.Completion.completeD)
	{
		string code;
		dc.extractD(completion, offset, code, offset);
		if (offset <= code.length && backend.hasBest!DCDComponent(file)
				&& backend.hasBest!DCDExtComponent(file))
		{
			auto dcdext = backend.best!DCDExtComponent(file);

			auto callParams = dcdext.extractCallParameters(code, cast(int) offset);
			if (callParams == CalltipsSupport.init)
				return SignatureHelp.init;

			auto dcd = backend.best!DCDComponent(file).listCompletion(code,
					callParams.functionParensRange[0] + 1).getYield;
			if (dcd.type == DCDCompletions.Type.calltips)
				return convertDCDCalltips(dcdext, dcd.calltips, dcd.symbols, callParams);
		}
	}
	return SignatureHelp.init;
}
