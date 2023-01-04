module served.commands.references;

import served.types;
import workspaced.com.index;
import workspaced.com.references;
import workspaced.com.dcd;

@protocolMethod("textDocument/references")
Location[] findReferences(ReferenceParams params)
{
	scope document = documents[params.textDocument.uri];
	auto offset = cast(int) document.positionToBytes(params.position);
	string file = document.uri.uriToFile;
	scope codeText = document.rawText;

	if (!backend.hasBest!DCDComponent(file))
		return null;
	auto refs = backend.best!ReferencesComponent(file)
		.findReferences(file, codeText, offset)
		.getYield();
	Location[] ret;
	if (params.context.includeDeclaration)
		resolveLocation(ret, refs.definitionFile, refs.definitionLocation);
	foreach (r; refs.references)
		resolveLocation(ret, r.file, r.location);
	return ret;
}

private void resolveLocation(ref Location[] ret, string file, int location)
{
	auto uri = file.uriFromFile;
	scope doc = documents.getOrFromFilesystem(uri);
	auto pos = doc.bytesToPosition(location);
	ret ~= Location(uri, doc.wordRangeAt(pos));
}
