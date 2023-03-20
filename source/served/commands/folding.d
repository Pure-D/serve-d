module served.commands.folding;

import std.array;

import served.types;
import served.types : FoldingRange;

import workspaced.api;
import workspaced.com.dcdext;

@protocolMethod("textDocument/foldingRange")
Nullable!(FoldingRange[]) provideFoldingRange(FoldingRangeParams params)
{
	scope document = documents[params.textDocument.uri];
	string file = document.uri.uriToFile;

	if (!backend.has!DCDExtComponent)
		return typeof(return).init;

	scope codeText = document.rawText;

	Position cachePos;
	size_t cacheBytes;

	auto ret = appender!(FoldingRange[]);
	foreach (range; backend.get!DCDExtComponent.getFoldingRanges(codeText))
	{
		auto start = document.nextPositionBytes(cachePos, cacheBytes, range.start);
		auto end = document.nextPositionBytes(cachePos, cacheBytes, range.end);
		FoldingRange converted = {
			startLine: start.line,
			endLine: end.line,
			startCharacter: start.character,
			endCharacter: end.character,
			kind: mapFoldingRangeKind(range.type)
		};
		ret ~= converted;
	}
	return typeof(return)(ret.data);
}

private FoldingRangeKind mapFoldingRangeKind(FoldingRangeType type)
{
	final switch (type) with (FoldingRangeType)
	{
		case comment: return FoldingRangeKind.comment;
		case imports: return FoldingRangeKind.imports;
		case region: return FoldingRangeKind.region;
	}
}
