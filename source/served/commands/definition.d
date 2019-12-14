module served.commands.definition;

import served.extension;
import served.types;
import served.utils.ddoc;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.coms;

import std.path : buildPath, isAbsolute;

import fs = std.file;
import io = std.stdio;

@protocolMethod("textDocument/definition")
ArrayOrSingle!Location provideDefinition(TextDocumentPositionParams params)
{
	auto instance = activeInstance = backend.getBestInstance!DCDComponent(
			params.textDocument.uri.uriToFile);
	if (!instance)
		return ArrayOrSingle!Location.init;

	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return ArrayOrSingle!Location.init;

	auto result = instance.get!DCDComponent.findDeclaration(document.rawText,
			cast(int) document.positionToBytes(params.position)).getYield;
	if (result == DCDDeclaration.init)
		return ArrayOrSingle!Location.init;

	auto uri = document.uri;
	if (result.file != "stdin")
	{
		if (isAbsolute(result.file))
			uri = uriFromFile(result.file);
		else
			uri = null;
	}
	size_t byteOffset = cast(size_t) result.position;
	Position pos;
	auto found = documents.tryGet(uri);
	if (found.uri)
		pos = found.bytesToPosition(byteOffset);
	else
	{
		string abs = result.file;
		if (!abs.isAbsolute)
			abs = buildPath(instance.cwd, abs);
		pos = Position.init;
		size_t totalLen;
		foreach (line; io.File(abs).byLine(io.KeepTerminator.yes))
		{
			totalLen += line.length;
			if (totalLen >= byteOffset)
				break;
			else
				pos.line++;
		}
	}
	return ArrayOrSingle!Location(Location(uri, TextRange(pos, pos)));
}

@protocolMethod("textDocument/hover")
Hover provideHover(TextDocumentPositionParams params)
{
	string file = params.textDocument.uri.uriToFile;

	if (!backend.hasBest!DCDComponent(file))
		return Hover.init;

	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return Hover.init;

	auto docs = backend.best!DCDComponent(file).getDocumentation(document.rawText,
			cast(int) document.positionToBytes(params.position)).getYield;
	Hover ret;
	ret.contents = docs.ddocToMarked;
	return ret;
}
