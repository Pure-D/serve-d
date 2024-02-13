/// Workspace-d component that provide import paths and errors from a
/// compile_commands.json file generated by a build system.
/// See https://clang.llvm.org/docs/JSONCompilationDatabase.html
module workspaced.com.ccdb;

import std.exception;
import std.json;
import std.path;
import fs = std.file;

import workspaced.api;
import workspaced.com.dcd;

import containers.hashset;
import workspaced.com.dub;

@component("ccdb")
class ClangCompilationDatabaseComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		trace("loading ccdb component");

		if (!refInstance)
			throw new Exception("ccdb requires to be instanced");

		if (config.get!bool("ccdb", "registerImportProvider", true))
			importPathProvider = &imports;
		if (config.get!bool("ccdb", "registerStringImportProvider", true))
			stringImportPathProvider = &stringImports;
		if (config.get!bool("ccdb", "registerImportFilesProvider", false))
			importFilesProvider = &fileImports;
		if (config.get!bool("ccdb", "registerProjectVersionsProvider", true))
			projectVersionsProvider = &versions;
		if (config.get!bool("ccdb", "registerDebugSpecificationsProvider", true))
			debugSpecificationsProvider = &debugVersions;

		if (auto dbPath = config.get!string("ccdb", "dbPath", null))
			loadDb(dbPath);
	}

	void setDbPath(string dbPath)
	{
		import std.path : buildNormalizedPath;

		if (dbPath.length)
			loadDb(dbPath);
		else
			unloadDb();

		config.set("ccdb", "dbPath", dbPath.buildNormalizedPath());

		if (refInstance.has!DCDComponent)
			refInstance.get!DCDComponent.refreshImports();
	}

	string getDbPath() const
	{
		return config.get!string("ccdb", "dbPath", null);
	}

	private void loadDb(string dbPath)
	{
		import std.algorithm : each, filter, map;
		import std.array : array;

		trace("parsing CCDB from ", dbPath);

		HashSet!string imports;
		HashSet!string stringImports;
		HashSet!string fileImports;
		HashSet!string versions;
		HashSet!string debugVersions;

		_compileCommands.clear();

		{
			string jsonString = cast(string) assumeUnique(fs.read(dbPath));
			auto json = parseJSON(jsonString);
			// clang db can be quite large (e.g. 100 k lines of JSON data on large projects)
			// we release memory when possible to avoid having at the same time more than
			// two represention of the same data
			jsonString = null;

			auto ccRng = json.array
				.map!(jv => CompileCommand.fromJson(jv))
				.filter!(cc => cc.isValid);

			foreach (cc; ccRng)
			{
				cc.feedOptions(imports, stringImports, fileImports, versions, debugVersions);
				_compileCommands[cc.getNormalizedFilePath()] = cc;
			}
		}

		_importPaths = imports[].array;
		_stringImportPaths = stringImports[].array;
		_importFiles = fileImports[].array;
		_versions = versions[].array;
		_debugVersions = debugVersions[].array;
	}

	private void unloadDb()
	{
		_importPaths = null;
		_stringImportPaths = null;
		_importFiles = null;
		_versions = null;
		_debugVersions = null;
		_compileCommands.clear();
	}

	/// Lists all import paths
	string[] imports() @property nothrow
	{
		return _importPaths;
	}

	/// Lists all string import paths
	string[] stringImports() @property nothrow
	{
		return _stringImportPaths;
	}

	/// Lists all import paths to files
	string[] fileImports() @property nothrow
	{
		return _importFiles;
	}

	/// Lists the currently defined versions
	string[] versions() @property nothrow
	{
		return _versions;
	}

	/// Lists the currently defined debug versions (debug specifications)
	string[] debugVersions() @property nothrow
	{
		return _debugVersions;
	}

	/// Return the compile command for the given D source file, or null if this file is not
	/// in the database.
	CompileCommand getCompileCommand(string filename) @property
	{
		auto normalized = buildNormalizedPath(filename);
		auto ccp = normalized in _compileCommands;
		if (ccp)
			return ccp.dup;
		return CompileCommand.init;
	}

private:

	string[] _importPaths, _stringImportPaths, _importFiles, _versions, _debugVersions;
	CompileCommand[string] _compileCommands;
}

public struct CompileCommand
{
	string directory;
	string file;
	string[] args;
	string output;

	private static CompileCommand fromJson(JSONValue json)
	{
		import std.algorithm : map;
		import std.array : array;

		CompileCommand cc;

		cc.directory = enforce("directory" in json, "'directory' missing from Clang compilation database entry")
			.str;
		cc.file = enforce("file" in json, "'file' missing from Clang compilation database entry")
			.str;

		if (auto args = "arguments" in json)
		{
			cc.args = args.array.map!(jv => jv.str).array;
		}
		else if (auto cmd = "command" in json)
		{
			cc.args = unescapeCommand(cmd.str);
		}
		else
		{
			throw new Exception(
				"Either 'arguments' or 'command' missing from Clang compilation database entry");
		}

		if (auto o = "output" in json)
		{
			cc.output = o.str;
		}

		return cc;
	}

	@property bool isValid() const
	{
		import std.algorithm : endsWith;

		if (args.length <= 1)
			return false;
		if (!file.endsWith(".d"))
			return false;
		return true;
	}

	bool opCast(T : bool)() const
	{
		return isValid;
	}

	@property CompileCommand dup() const
	{
		return CompileCommand(directory, file, args.dup, output);
	}

	string getNormalizedFilePath() const
	{
		return getPath(file).buildNormalizedPath();
	}

	string getPath(string filename) const
	{
		import std.path : absolutePath;

		return absolutePath(filename, directory);
	}

	Future!(BuildIssue[]) run() const
	{
		import std.algorithm : canFind, remove;
		import std.process : Config, execute;

		return Future!(BuildIssue[]).async({
			trace("stripping color from ", args);
			string[] program = args.dup.remove!(a => a.canFind("-color=on") || a.canFind(
				"-enable-color"));
			trace("running ", program);
			auto res = execute(program, null, Config.none, size_t.max, directory);
			trace(res.status, " ", res.output);
			auto issues = parseBuildIssues(res.output);
			trace("found ", issues.length, " issue(s)!");
			return issues;
		});
	}
}

void feedOptions(
	in CompileCommand cc,
	ref HashSet!string imports,
	ref HashSet!string stringImports,
	ref HashSet!string fileImports,
	ref HashSet!string versions,
	ref HashSet!string debugVersions)
{
	import std.algorithm : startsWith;

	enum importMark = "-I"; // optional =
	enum stringImportMark = "-J"; // optional =
	enum fileImportMark = "-i=";
	enum dmdVersionMark = "-version=";
	enum ldcVersionMark = "--d-version=";
	enum dmdDebugMark = "-debug=";
	enum ldcDebugMark = "--d-debug=";

	foreach (arg; cc.args)
	{
		const mark = arg.startsWith(
			importMark, stringImportMark, fileImportMark, dmdVersionMark, ldcVersionMark, dmdDebugMark, ldcDebugMark,
		);

		switch (mark)
		{
		case 0:
			break;
		case 1:
		case 2:
			if (arg.length == 2)
				break; // ill-formed flag, we don't need to care here
			const st = arg[2] == '=' ? 3 : 2;
			const path = cc.getPath(arg[st .. $]);
			if (mark == 1)
				imports.put(path);
			else
				stringImports.put(path);
			break;
		case 3:
			fileImports.put(cc.getPath(arg[fileImportMark.length .. $]));
			break;
		case 4:
			versions.put(arg[dmdVersionMark.length .. $]);
			break;
		case 5:
			versions.put(arg[ldcVersionMark.length .. $]);
			break;
		case 6:
			debugVersions.put(arg[dmdDebugMark.length .. $]);
			break;
		case 7:
			debugVersions.put(arg[ldcDebugMark.length .. $]);
			break;
		default:
			break;
		}
	}
}

private string[] unescapeCommand(string cmd)
{
	string[] result;
	string current;

	bool inquot;
	bool escapeNext;

	foreach (dchar c; cmd)
	{
		if (escapeNext)
		{
			escapeNext = false;
			if (c != '"')
			{
				current ~= '\\';
			}
			current ~= c;
			continue;
		}

		switch (c)
		{
		case '\\':
			escapeNext = true;
			break;
		case '"':
			inquot = !inquot;
			break;
		case ' ':
			if (inquot)
			{
				current ~= ' ';
			}
			else
			{
				result ~= current;
				current = null;
			}
			break;
		default:
			current ~= c;
			break;
		}
	}

	if (current.length)
	{
		result ~= current;
	}
	return result;
}

@("unescapeCommand")
unittest
{
	const cmd = `"ldc2" "-I=..\foo\src" -I="..\with \" and space" "-m64" ` ~
		`-of=foo/libfoo.a.p/src_foo_bar.d.obj -c ../foo/src/foo/bar.d`;

	const cmdArgs = unescapeCommand(cmd);

	const args = [
		"ldc2", "-I=..\\foo\\src", "-I=..\\with \" and space", "-m64",
		"-of=foo/libfoo.a.p/src_foo_bar.d.obj", "-c", "../foo/src/foo/bar.d",
	];

	assert(cmdArgs == args);
}
