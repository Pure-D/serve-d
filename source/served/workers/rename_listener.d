module served.workers.rename_listener;

import std.algorithm;
import std.array;
import std.datetime;
import std.experimental.logger;
import std.path;
import std.string;

import served.extension;
import served.types;
import served.utils.translate;

import workspaced.com.moduleman : ModulemanComponent;

/// Helper struct which contains information about a recently opened and/or created file
struct FileOpenInfo
{
	/// When the file first was accessed recently
	SysTime at;
	/// The uri of the file
	DocumentUri uri;
	/// Whether the file has only been created, opened or both
	bool created, opened;

	/// Returns: true when the FileOpenInfo should no longer be used (after 5 seconds)
	bool expired(SysTime now) const
	{
		return at == SysTime.init || (now - at) > 5.seconds;
	}

	/// Sets created to true and triggers onFullyCreate if it is also opened
	void setCreated()
	{
		created = true;
		if (opened)
			onFullyCreate(uri);
	}

	/// Sets opened to true and triggers onFullyCreate if it is also created
	void setOpened()
	{
		opened = true;
		if (created)
			onFullyCreate(uri);
	}
}

/// Helper struct to keep track of recently opened & created files
struct RecentFiles
{
	/// the last 8 files
	FileOpenInfo[8] infos;

	/// Returns a reference to some initialized FileOpenInfo with this uri
	ref FileOpenInfo get(DocumentUri uri)
	{
		auto now = Clock.currTime;

		// find existing one
		foreach (ref info; infos)
		{
			if (info.uri == uri)
			{
				if (info.expired(now))
				{
					info.created = false;
					info.opened = false;
				}
				return info;
			}
		}

		// replace old one
		size_t min;
		SysTime minTime = now;
		foreach (i, ref info; infos)
		{
			if (info.at < minTime)
			{
				minTime = info.at;
				min = i;
			}
		}

		infos[min].at = now;
		infos[min].created = infos[min].opened = false;
		infos[min].uri = uri;
		return infos[min];
	}
}

package __gshared RecentFiles recentFiles;

@protocolNotification("workspace/didChangeWatchedFiles")
void markRecentlyChangedFile(DidChangeWatchedFilesParams params)
{
	foreach (change; params.changes)
		if (change.type == FileChangeType.created)
			markRecentFileCreated(change.uri);
}

void markRecentFileCreated(DocumentUri uri)
{
	recentFiles.get(uri).setCreated();
}

@protocolNotification("textDocument/didOpen")
void markRecentFileOpened(DidOpenTextDocumentParams params)
{
	recentFiles.get(params.textDocument.uri).setOpened();
}

/// Called when a file has been created or renamed and opened within a short time frame by the user
/// Indicating it was created to be edited in the IDE
void onFullyCreate(DocumentUri uri)
{
	trace("handle file creation/rename for ", uri);
	if (uri.endsWith(".d"))
		return onFullyCreateDSource(uri);

	auto file = baseName(uri);
	if (file == "dub.json")
		onFullyCreateDubJson(uri);
	else if (file == "dub.sdl")
		onFullyCreateDubSdl(uri);
}

void onFullyCreateDSource(DocumentUri uri)
{
	string workspace = workspaceRootFor(uri);
	auto document = documents[uri];
	// Sending applyEdit so it is undoable
	auto patches = backend.get!ModulemanComponent(workspace)
		.normalizeModules(uri.uriToFile, document.rawText);
	if (patches.length)
	{
		WorkspaceEdit edit;
		edit.changes[uri] = patches.map!(a => TextEdit(TextRange(document.bytesToPosition(a.range[0]),
				document.bytesToPosition(a.range[1])), a.content)).array;
		rpc.sendMethod("workspace/applyEdit", ApplyWorkspaceEditParams(edit));
		rpc.window.showInformationMessage(translate!"d.served.moduleNameAutoUpdated");
	}
}

void onFullyCreateDubJson(DocumentUri uri)
{
	auto document = documents[uri];
	if (document.rawText.strip.length == 0)
	{
		string packageName = determineDubPackageName(uri.uriToFile.dirName);
		WorkspaceEdit edit;
		edit.changes[uri] = [
			TextEdit(TextRange(0, 0, 0, 0), "{\n\t\"name\": \"" ~ packageName ~ "\"\n}")
		];
		rpc.sendMethod("workspace/applyEdit", ApplyWorkspaceEditParams(edit));
	}
}

void onFullyCreateDubSdl(DocumentUri uri)
{
	auto document = documents[uri];
	if (document.rawText.strip.length == 0)
	{
		string packageName = determineDubPackageName(uri.uriToFile.dirName);
		WorkspaceEdit edit;
		edit.changes[uri] = [
			TextEdit(TextRange(0, 0, 0, 0), `name "` ~ packageName ~ `"` ~ '\n')
		];
		rpc.sendMethod("workspace/applyEdit", ApplyWorkspaceEditParams(edit));
	}
}

/// Generates a package name for a given folder path
string determineDubPackageName(string directory)
{
	import std.ascii : toLower, isUpper, isAlphaNum;

	auto name = baseName(directory);
	if (!name.length)
		return "";

	auto ret = appender!string;
	ret.put(toLower(name[0]));
	bool wasUpper = name[0].isUpper;
	bool wasDash = false;
	foreach (char c; name[1 .. $])
	{
		if (!isAlphaNum(c) && c != '_')
			c = '-';

		if (wasDash && c == '-')
			continue;
		wasDash = c == '-';

		if (c.isUpper)
		{
			if (!wasUpper)
			{
				ret.put('-');
				ret.put(c.toLower);
			}
			wasUpper = true;
		}
		else
		{
			wasUpper = false;
			ret.put(c);
		}
	}
	auto packageName = ret.data;
	while (packageName.startsWith("-"))
		packageName = packageName[1 .. $];
	while (packageName.endsWith("-"))
		packageName = packageName[0 .. $ - 1];
	return packageName;
}
