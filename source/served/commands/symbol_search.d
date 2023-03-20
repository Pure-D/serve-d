module served.commands.symbol_search;

import served.extension;
import served.types;

import mir.serde;

import workspaced.api;
import workspaced.coms;
import workspaced.com.dscanner : DefinitionElement;
import workspaced.com.index;

import std.algorithm : among, canFind, filter, map;
import std.array : appender, array, join;
import std.path : extension, isAbsolute;
import std.string : toLower;

import fs = std.file;
import io = std.stdio;

@protocolMethod("workspace/symbol")
SymbolInformation[] provideWorkspaceSymbols(WorkspaceSymbolParams params)
{
	import fuzzymatch;

	auto infos = appender!(SymbolInformation[]);
	foreach (workspace; workspaces)
	{
		auto folderPath = workspace.folder.uri.uriToFile;
		if (workspace.config.d.enableIndex && backend.has!IndexComponent(folderPath))
		{
			auto indexer = backend.get!IndexComponent(folderPath);
			indexer.iterateAll(delegate(ModuleRef mod, string fileName, scope const ref DefinitionElement def) {
				if (def.isImportable
					&& !mod.isStdLib
					&& def.name.fuzzyMatchesString(params.query))
				{
					Position p;
					p.line = def.line - 1;
					auto info = makeSymbolInfoEx(def, fileName.uriFromFile, p, p).downcast;
					if (info.containerName.isNone)
						info.containerName = mod;
					infos ~= info;
				}
			});
		}
	}
	return infos.data;
}

@protocolMethod("textDocument/documentSymbol")
JsonValue provideDocumentSymbols(DocumentSymbolParams params)
{
	if (capabilities
		.textDocument.orDefault
		.documentSymbol.orDefault
		.hierarchicalDocumentSymbolSupport.orDefault)
		return provideDocumentSymbolsHierarchical(params).toJsonValue;
	else
		return provideDocumentSymbolsOld(DocumentSymbolParamsEx(params)).map!"a.downcast".array.toJsonValue;
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
		.listDefinitions(uriToFile(params.textDocument.uri), document.rawText, true).getYield
		.definitions;
	auto ret = appender!(SymbolInformationEx[]);
	auto retVerbose = appender!(SymbolInformationEx[]);

	size_t cacheByte = size_t.max;
	Position cachePosition;

	foreach (def; result)
	{
		auto startPosition = document.movePositionBytes(cachePosition, cacheByte, def.range[0]);
		auto endPosition = document.movePositionBytes(startPosition, def.range[0], def.range[1]);
		cacheByte = def.range[1];
		cachePosition = endPosition;

		auto info = makeSymbolInfoEx(def, params.textDocument.uri, startPosition, endPosition);
		if (!def.isVerboseType)
			ret.put(info);
		retVerbose.put(info);
	}
	documentSymbolsCacheOld.store(document, OldSymbolsCache(ret.data, retVerbose.data));

	return params.verbose ? retVerbose.data : ret.data;
}

SymbolInformationEx makeSymbolInfoEx(scope const ref DefinitionElement def, string uri, Position startPosition, Position endPosition)
{
	SymbolInformationEx info;
	info.name = def.name;
	info.location.uri = uri;
	info.location.range = TextRange(startPosition, endPosition);
	info.kind = convertFromDscannerType(def.type, def.name);
	info.extendedType = convertExtendedFromDscannerType(def.type);
	const(string)* ptr;
	auto attribs = def.attributes;
	if ((ptr = "struct" in attribs) !is null || (ptr = "class" in attribs) !is null
			|| (ptr = "enum" in attribs) !is null || (ptr = "union" in attribs) !is null)
		info.containerName = *ptr;
	if ("deprecation" in attribs)
		info.tags = [SymbolTag.deprecated_];
	if (auto name = "name" in attribs)
		info.detail = *name;
	return info;
}

@serdeProxy!DocumentSymbol
struct DocumentSymbolInfo
{
	DocumentSymbol symbol;
	string parent;
	alias symbol this;
}

PerDocumentCache!(DocumentSymbolInfo[]) documentSymbolsCacheHierarchical;
DocumentSymbolInfo[] provideDocumentSymbolsHierarchical(DocumentSymbolParams params)
{
	auto cached = documentSymbolsCacheHierarchical.cached(documents, params.textDocument.uri);
	if (cached.length)
		return cached;
	DocumentSymbolInfo[] all;
	auto symbols = provideDocumentSymbolsOld(DocumentSymbolParamsEx(params));
	foreach (symbol; symbols)
	{
		DocumentSymbolInfo sym;
		static foreach (member; __traits(allMembers, SymbolInformationEx))
			static if (__traits(hasMember, DocumentSymbolInfo, member))
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

	DocumentSymbolInfo[] ret = all.filter!(a => a.parent.length == 0).array;
	documentSymbolsCacheHierarchical.store(documents.tryGet(params.textDocument.uri), ret);
	return ret;
}
