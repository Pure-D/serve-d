/// Clang compilation database (aka. compile_commands.json) related functions
module served.commands.ccdb;

import served.io.nothrow_fs;
import served.lsp.protocol;
import served.lsp.uri;
import served.types;
import served.utils.events;

import std.experimental.logger;
import fs = std.file;
import std.path;

import workspaced.api;
import workspaced.coms;

string discoverCcdb(string root)
{
	import std.algorithm : count, map, sort;
	import std.array : array;

	trace("discovering CCDB in ", root);

	if (fs.exists(chainPath(root, "compile_commands.json")))
		return buildNormalizedPath(root, "compile_commands.json");

	string[] dbs = tryDirEntries(root, "compile_commands.json", fs.SpanMode.breadth)
		.map!(e => buildNormalizedPath(e.name))
		.array;

	// using in priority:
	//  - those which have fewer directory depth
	//  - lexical order
	dbs.sort!((a, b) {
		const depthA = count(a, dirSeparator);
		const depthB = count(b, dirSeparator);
		if (depthA != depthB)
			return depthA < depthB;
		return a < b;
	});

	tracef("discovered following CCDB:%-(\n - %s%)", dbs);

	return dbs.length ? dbs[0] : null;
}

@protocolNotification("workspace/didChangeWatchedFiles")
void onCcdbFileChange(DidChangeWatchedFilesParams params)
{
	import std.algorithm : endsWith, map;

	foreach (c; params.changes)
	{
		trace("watched file did change: ", c);

		if (!c.uri.endsWith("compile_commands.json"))
			continue;

		string filename = c.uri.uriToFile;

		auto inst = backend.getBestInstance!ClangCompilationDatabaseComponent(filename);
		if (!inst)
			continue;

		string ccdbPath = inst.get!ClangCompilationDatabaseComponent.getDbPath();
		if (!ccdbPath)
			continue;

		filename = filename.buildNormalizedPath();

		if (filename == ccdbPath)
		{
			if (c.type == FileChangeType.deleted)
			{
				filename = discoverCcdb(inst.cwd);
				tracef("CCDB file deleted. Switching from %s to %s", ccdbPath, filename ? filename
						: "(null)");
			}

			tracef("will (re)load %s", filename);
			inst.get!ClangCompilationDatabaseComponent.setDbPath(filename);
		}
	}
}
