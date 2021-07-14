module served.commands.highlight;

import std.experimental.logger;

import served.types;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.com.dcdext;

@protocolMethod("textDocument/documentHighlight")
DocumentHighlight[] provideDocumentHighlight(DocumentHighlightParams params)
{
	scope immutable document = documents[params.textDocument.uri].clone();
	string file = document.uri.uriToFile;
	auto currOffset = cast(int) document.positionToBytes(params.position);

	if (!backend.hasBest!DCDComponent(file))
		return fallbackDocumentHighlight(document, currOffset);

	DocumentHighlight[] result;
	string codeText = document.rawText;

	Position cachePos;
	size_t cacheBytes;

	auto localUse = backend.best!DCDComponent(file).findLocalUse(codeText, currOffset).getYield;
	trace("localUse: ", localUse);
	if (localUse.declarationFilePath == "stdin")
	{
		auto range = document.wordRangeAt(localUse.declarationLocation);
		auto start = document.nextPositionBytes(cachePos, cacheBytes, range[0]);
		auto end = document.nextPositionBytes(cachePos, cacheBytes, range[1]);
		result ~= DocumentHighlight(TextRange(start, end), DocumentHighlightKind.write.opt);
	}

	foreach (use; localUse.uses)
	{
		auto range = document.wordRangeAt(use);
		auto start = document.nextPositionBytes(cachePos, cacheBytes, range[0]);
		auto end = document.nextPositionBytes(cachePos, cacheBytes, range[1]);
		result ~= DocumentHighlight(TextRange(start, end), DocumentHighlightKind.read.opt);
	}

	if (!result.length)
		return fallbackDocumentHighlight(document, currOffset);

	return result;
}

private DocumentHighlight[] fallbackDocumentHighlight(scope ref immutable(Document) document, int currOffset)
{
	string file = document.uri.uriToFile;
	if (!backend.hasBest!DCDExtComponent(file))
		return null;

	DocumentHighlight[] result;
	string codeText = document.rawText;

	Position cachePos;
	size_t cacheBytes;

	foreach (related; backend.best!DCDExtComponent(file).highlightRelated(codeText, currOffset))
	{
		auto start = document.nextPositionBytes(cachePos, cacheBytes, related.range[0]);
		auto end = document.nextPositionBytes(cachePos, cacheBytes, related.range[1]);
		result ~= DocumentHighlight(TextRange(start, end), DocumentHighlightKind.text.opt);
	}

	return result;
}
