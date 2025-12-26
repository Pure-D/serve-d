module served.commands.inlay_hints;

import served.lsp.protocol;
import served.types;
import served.utils.events;
import std.array;
import workspaced.com.dcd : DCDComponent;

@protocolMethod("textDocument/inlayHint")
InlayHint[] provideInlayHints(InlayHintParams params)
{
	auto instance = activeInstance = backend.getBestInstance!DCDComponent(
			params.textDocument.uri.uriToFile);
	if (!instance)
		return null;

	auto document = documents[params.textDocument.uri];
	if (document.getLanguageId != "d")
		return null;

	auto result = instance.get!DCDComponent.getInlayHints(document.rawText).getYield;
	if (!result.length)
		return null;

	Position cachePosition;
	size_t cacheIndex;

	auto res = appender!(InlayHint[]);
	foreach (part; result)
	{
		InlayHint hint;
		switch (part.kind)
		{
		case 'l':
			hint.kind = opt(InlayHintKind.type);
			break;
		default:
			break;
		}
		hint.position = document.movePositionBytes(cachePosition, cacheIndex, part.symbolLocation);
		hint.label = part.identifier;
		res ~= hint;
	}
	return res.data;
}
