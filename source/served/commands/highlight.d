module served.commands.highlight;

import std.experimental.logger;

import served.types;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.com.dcdext;

@protocolMethod("textDocument/documentHighlight")
DocumentHighlight[] provideDocumentHighlight(DocumentHighlightParams params)
{
	scope document = cast(immutable)documents[params.textDocument.uri].clone();
	auto currOffset = cast(int) document.positionToBytes(params.position);
	auto fileConfig = config(document.uri);

	auto result = fileConfig.d.enableDCDHighlight ? documentHighlightImpl(document, currOffset) : null;

	if (!result.length && fileConfig.d.enableFallbackHighlight)
		return fallbackDocumentHighlight(document, currOffset);

	return result;
}

package DocumentHighlight[] documentHighlightImpl(scope ref immutable(Document) document, int currOffset)
{
	string file = document.uri.uriToFile;
	string codeText = document.rawText;

	if (!backend.hasBest!DCDComponent(file))
		return null;

	DocumentHighlight[] result;

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

	return result;
}

package DocumentHighlight[] fallbackDocumentHighlight(scope ref immutable(Document) document, int currOffset)
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
