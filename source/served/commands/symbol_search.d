module served.commands.symbol_search;

import served.extension;
import served.types;

import workspaced.api;
import workspaced.coms;

import std.algorithm : canFind, filter, map, startsWith;
import std.array : array, appender;
import std.json : JSONValue;
import std.path : extension, isAbsolute;
import std.string : toLower;

import fs = std.file;
import io = std.stdio;

@protocolMethod("workspace/symbol")
SymbolInformation[] provideWorkspaceSymbols(WorkspaceSymbolParams params)
{
	SymbolInformation[] infos;
	foreach (workspace; workspaces)
	{
		string workspaceRoot = workspace.folder.uri.uriToFile;
		foreach (file; fs.dirEntries(workspaceRoot, fs.SpanMode.depth, false))
		{
			if (!file.isFile || file.extension != ".d")
				continue;
			auto defs = provideDocumentSymbolsOld(
					DocumentSymbolParamsEx(TextDocumentIdentifier(file.uriFromFile), false));
			foreach (def; defs)
				if (def.name.toLower.startsWith(params.query.toLower))
					infos ~= def.downcast;
		}
		if (backend.has!DCDComponent(workspace.folder.uri.uriToFile))
		{
			auto exact = backend.get!DCDComponent(workspace.folder.uri.uriToFile)
				.searchSymbol(params.query).getYield;
			foreach (symbol; exact)
			{
				if (!symbol.file.isAbsolute)
					continue;
				string uri = symbol.file.uriFromFile;
				if (infos.canFind!(a => a.location.uri == uri))
					continue;
				SymbolInformation info;
				info.name = params.query;
				info.location.uri = uri;
				auto doc = documents.tryGet(uri);
				if (doc != Document.init)
					info.location.range = TextRange(doc.bytesToPosition(symbol.position));
				info.kind = symbol.type.convertFromDCDSearchType;
				infos ~= info;
			}
		}
	}
	return infos;
}

@protocolMethod("textDocument/documentSymbol")
JSONValue provideDocumentSymbols(DocumentSymbolParams params)
{
	import painlessjson : toJSON;

	if (capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport)
		return provideDocumentSymbolsHierarchical(params).toJSON;
	else
		return provideDocumentSymbolsOld(DocumentSymbolParamsEx(params)).map!"a.downcast".array.toJSON;
}

private struct OldSymbolsCache
{
	SymbolInformationEx[] symbols;
	SymbolInformationEx[] symbolsVerbose;
}

PerDocumentCache!OldSymbolsCache documentSymbolsCacheOld;
SymbolInformationEx[] provideDocumentSymbolsOld(DocumentSymbolParamsEx params)
{
	if (!backend.hasBest!DscannerComponent(params.textDocument.uri.uriToFile))
		return null;

	auto cached = documentSymbolsCacheOld.cached(documents, params.textDocument.uri);
	if (cached.symbolsVerbose.length)
		return params.verbose ? cached.symbolsVerbose : cached.symbols;
	auto document = documents.tryGet(params.textDocument.uri);
	if (document.languageId != "d")
		return null;

	auto result = backend.best!DscannerComponent(params.textDocument.uri.uriToFile)
		.listDefinitions(uriToFile(params.textDocument.uri), document.rawText, true).getYield;
	auto ret = appender!(SymbolInformationEx[]);
	auto retVerbose = appender!(SymbolInformationEx[]);

	size_t cacheByte = size_t.max;
	Position cachePosition;

	foreach (def; result)
	{
		SymbolInformationEx info;
		info.name = def.name;
		info.location.uri = params.textDocument.uri;

		auto startPosition = document.movePositionBytes(cachePosition, cacheByte, def.range[0]);
		auto endPosition = document.movePositionBytes(startPosition, def.range[0], def.range[1]);
		cacheByte = def.range[1];
		cachePosition = endPosition;

		info.location.range = TextRange(startPosition, endPosition);
		info.kind = convertFromDscannerType(def.type, def.name);
		info.extendedType = convertExtendedFromDscannerType(def.type);
		if (def.type == "f" && def.name == "this")
			info.kind = SymbolKind.constructor;
		string* ptr;
		auto attribs = def.attributes;
		if ((ptr = "struct" in attribs) !is null || (ptr = "class" in attribs) !is null
				|| (ptr = "enum" in attribs) !is null || (ptr = "union" in attribs) !is null)
			info.containerName = *ptr;
		if ("deprecation" in attribs)
			info.deprecated_ = true;
		if (auto name = "name" in attribs)
			info.detail = *name;

		if (!def.isVerboseType)
			ret.put(info);
		retVerbose.put(info);
	}
	documentSymbolsCacheOld.store(document, OldSymbolsCache(ret.data, retVerbose.data));

	return params.verbose ? retVerbose.data : ret.data;
}

PerDocumentCache!(DocumentSymbol[]) documentSymbolsCacheHierarchical;
DocumentSymbol[] provideDocumentSymbolsHierarchical(DocumentSymbolParams params)
{
	auto cached = documentSymbolsCacheHierarchical.cached(documents, params.textDocument.uri);
	if (cached.length)
		return cached;
	DocumentSymbol[] all;
	auto symbols = provideDocumentSymbolsOld(DocumentSymbolParamsEx(params));
	foreach (symbol; symbols)
	{
		DocumentSymbol sym;
		static foreach (member; __traits(allMembers, SymbolInformationEx))
			static if (__traits(hasMember, DocumentSymbol, member))
				__traits(getMember, sym, member) = __traits(getMember, symbol, member);
		sym.parent = symbol.containerName;
		sym.range = sym.selectionRange = symbol.location.range;
		sym.selectionRange.end.line = sym.selectionRange.start.line;
		if (sym.selectionRange.end.character < sym.selectionRange.start.character)
			sym.selectionRange.end.character = sym.selectionRange.start.character;
		all ~= sym;
	}

	foreach (ref sym; all)
	{
		if (sym.parent.length)
		{
			foreach (ref other; all)
			{
				if (other.name == sym.parent)
				{
					other.children ~= sym;
					break;
				}
			}
		}
	}

	DocumentSymbol[] ret = all.filter!(a => a.parent.length == 0).array;
	documentSymbolsCacheHierarchical.store(documents.tryGet(params.textDocument.uri), ret);
	return ret;
}
