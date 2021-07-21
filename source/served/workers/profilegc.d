module served.workers.profilegc;

import std.algorithm;
import std.array;
import std.ascii : isDigit;
import std.conv;
import std.experimental.logger;
import std.format;
import std.json;
import std.string;

import served.types;

import workspaced.api;

import painlessjson;

struct ProfileGCEntry
{
	size_t bytesAllocated;
	size_t allocationCount;
	string type;
	string uri, displayFile;
	uint line;
}

struct ProfileGCCache
{
	struct PerDocumentCache
	{
		ProfileGCEntry[] entries;

		auto process(DocumentUri relativeToUri, scope const(char)[] content)
		{
			entries = null;
			foreach (line; content.lineSplitter)
			{
				auto cols = line.split;
				if (cols.length < 5)
					continue;
				auto typeStart = cols[2].ptr - line.ptr;
				if (typeStart < 0 || typeStart > line.length)
					typeStart = 0;
				auto fileStart = line.lastIndexOfAny(" \t");
				if (fileStart != -1)
				{
					fileStart++;
					auto colon = line.indexOf(":", fileStart);
					if (colon != -1 && line[colon + 1 .. $].strip.all!isDigit)
					{
						auto file = line[fileStart .. colon];
						auto lineNo = line[colon + 1 .. $].strip.to!uint;
						entries.assumeSafeAppend ~= ProfileGCEntry(
							cols[0].to!size_t,
							cols[1].to!size_t,
							line[typeStart .. fileStart - 1].strip.idup,
							uriBuildNormalized(relativeToUri, file),
							file.idup,
							lineNo
						);
					}
				}
			}
			return entries;
		}
	}

	PerDocumentCache[DocumentUri] caches;

	void update(DocumentUri uri)
	{
		try
		{
			auto profileGC = documents.getOrFromFilesystem(uri);
			trace("Processing profilegc.log ", uri);
			auto entries = caches.require(uri).process(uri.uriDirName, profileGC.rawText);
			// trace("Processed: ", entries);
		}
		catch (Exception e)
		{
			trace("Exception processing profilegc: ", e);
			caches.remove(uri);
		}
	}

	void clear(DocumentUri uri)
	{
		trace("Clearing profilegc.log cache from ", uri);
		caches.remove(uri);
	}
}

package __gshared ProfileGCCache profileGCCache;

@protocolMethod("textDocument/codeLens")
CodeLens[] provideProfileGCCodeLens(CodeLensParams params)
{
	if (!config(params.textDocument.uri).d.enableGCProfilerDecorations)
		return null;

	auto lenses = appender!(CodeLens[]);
	foreach (url, cache; profileGCCache.caches)
	{
		foreach (entry; cache.entries)
		{
			if (entry.uri == params.textDocument.uri)
			{
				lenses ~= CodeLens(
					TextRange(entry.line - 1, 0, entry.line - 1, 1),
					Command(format!"%s bytes allocated / %s allocations"(entry.bytesAllocated, entry.allocationCount)).opt
				);
			}
		}
	}
	return lenses.data;
}

@protocolMethod("served/getProfileGCEntries")
ProfileGCEntry[] getProfileGCEntries()
{
	auto lenses = appender!(ProfileGCEntry[]);
	foreach (url, cache; profileGCCache.caches)
		lenses ~= cache.entries;
	return lenses.data;
}

@onRegisteredComponents
void setupProfileGCWatchers()
{
	if (capabilities.workspace.didChangeWatchedFiles.dynamicRegistration)
	{
		rpc.sendRequest("client/registerCapability",
			Registration(
				"profilegc.watchfiles",
				"workspace/didChangeWatchedFiles",
				JSONValue([
					"watchers": JSONValue([
						FileSystemWatcher("**/profilegc.log").toJSON
					])
				])
			)
		);
	}
}

@onProjectAvailable
void onProfileGCProjectAvailable(WorkspaceD.Instance instance, string dir, string uri)
{
	profileGCCache.update(uri.chomp("/") ~ "/profilegc.log");
}

@protocolNotification("workspace/didChangeWatchedFiles")
void onChangeProfileGC(DidChangeWatchedFilesParams params)
{
	foreach (change; params.changes)
	{
		if (!change.uri.endsWith("profilegc.log"))
			continue;

		if (change.type == FileChangeType.created
		 || change.type == FileChangeType.changed)
			profileGCCache.update(change.uri);
		else if (change.type == FileChangeType.deleted)
			profileGCCache.clear(change.uri);
	}
}
