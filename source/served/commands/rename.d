module served.commands.rename;

import std.algorithm;
import std.experimental.logger;

import served.types;
import served.commands.highlight;

import workspaced.api;
import workspaced.com.dcd;

@protocolMethod("textDocument/rename")
Nullable!WorkspaceEdit provideRename(RenameParams params)
{
	scope document = cast(immutable)documents[params.textDocument.uri].clone();
	auto currOffset = cast(int) document.positionToBytes(params.position);

	auto highlight = documentHighlightImpl(document, currOffset);
	if (highlight.length && highlight[0].kind == DocumentHighlightKind.write)
	{
		TextEdit[] edits;
		foreach (i, h; highlight)
			if (i == 0 || h.range != edits[0].range)
				edits ~= TextEdit(h.range, params.newName);
		WorkspaceEdit edit;
		edits.sort!"a.range.start>b.range.start";
		edit.changes[params.textDocument.uri] = edits;
		return typeof(return)(edit);
	}

	return typeof(return).init;
}

@protocolMethod("textDocument/prepareRename")
Nullable!TextRange prepareRename(PrepareRenameParams params)
{
	scope document = cast(immutable)documents[params.textDocument.uri].clone();
	auto currOffset = cast(int) document.positionToBytes(params.position);

	auto highlight = documentHighlightImpl(document, currOffset);
	if (highlight.length && highlight[0].kind == DocumentHighlightKind.write)
		return typeof(return)(highlight[0].range);

	return typeof(return).init;
}
