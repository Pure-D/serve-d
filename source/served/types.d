module served.types;

public import served.lsp.protocol;
public import served.lsp.protoext;
public import served.lsp.textdocumentmanager;

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.experimental.logger;
import std.json;
import std.meta;
import std.path;
import std.process : environment;
import std.range;
import std.string;
import std.uni : sicmp;
import std.utf;

import fs = std.file;
import io = std.stdio;

import workspaced.api;

import served.lsp.jsonrpc;

struct protocolMethod
{
	string method;
}

struct postProtocolMethod
{
	string method;
}

struct protocolNotification
{
	string method;
}

enum IncludedFeatures = ["d", "workspaces"];

TextDocumentManager documents;

string[] compare(string prefix, T)(ref T a, ref T b)
{
	auto changed = appender!(string[]);
	foreach (member; __traits(allMembers, T))
		if (__traits(getMember, a, member) != __traits(getMember, b, member))
			changed ~= (prefix ~ member);
	return changed.data;
}

alias configurationTypes = AliasSeq!(Configuration.D, Configuration.DFmt,
		Configuration.DScanner, Configuration.Editor, Configuration.Git);
static immutable string[] configurationSections = [
	"d", "dfmt", "dscanner", "editor", "git"
];

enum ManyProjectsAction : string
{
	ask = "ask",
	skip = "skip",
	load = "load"
}

// alias to avoid name clashing
alias UserConfiguration = Configuration;
struct Configuration
{
	struct D
	{
		JSONValue stdlibPath = JSONValue("auto");
		string dcdClientPath = "dcd-client", dcdServerPath = "dcd-server";
		string dubPath = "dub";
		string dmdPath = "dmd";
		bool enableLinting = true;
		bool enableSDLLinting = true;
		bool enableStaticLinting = true;
		bool enableDubLinting = true;
		bool enableAutoComplete = true;
		bool enableFormatting = true;
		bool enableDMDImportTiming = false;
		bool neverUseDub = false;
		string[] projectImportPaths;
		string dubConfiguration;
		string dubArchType;
		string dubBuildType;
		string dubCompiler;
		bool overrideDfmtEditorconfig = true;
		bool aggressiveUpdate = false; // differs from default code-d settings on purpose!
		bool argumentSnippets = false;
		bool completeNoDupes = true;
		bool scanAllFolders = true;
		string[] disabledRootGlobs;
		string[] extraRoots;
		ManyProjectsAction manyProjectsAction = ManyProjectsAction.ask;
		int manyProjectsThreshold = 4;
		string lintOnFileOpen = "project";
		bool dietContextCompletion = false;
	}

	struct DFmt
	{
		bool alignSwitchStatements = true;
		string braceStyle = "allman";
		bool outdentAttributes = true;
		bool spaceAfterCast = true;
		bool splitOperatorAtLineEnd = false;
		bool selectiveImportSpace = true;
		bool compactLabeledStatements = true;
		string templateConstraintStyle = "conditional_newline_indent";
	}

	struct DScanner
	{
		string[] ignoredKeys;
	}

	struct Editor
	{
		int[] rulers;
		int tabSize;
	}

	struct Git
	{
		string path = "git";
	}

	D d;
	DFmt dfmt;
	DScanner dscanner;
	Editor editor;
	Git git;

	string[] stdlibPath(string cwd = null)
	{
		auto p = d.stdlibPath;
		if (p.type == JSONType.array)
			return p.array.map!(a => a.str.userPath).array;
		else
		{
			if (p.type != JSONType.string || p.str == "auto")
			{
				string[] ret;
				if (cwd.length && fs.exists(chainPath(cwd, "dmd.conf"))
						&& parseDmdConfImports(buildPath(cwd, "dmd.conf"), ret))
					return ret;

				version (Windows)
				{
					auto dmdPath = searchPathFor("dmd.exe");
					if (dmdPath.length)
					{
						auto dmdDir = dirName(dmdPath);
						if (fs.exists(chainPath(dmdDir, "dmd.conf"))
								&& parseDmdConfImports(buildPath(dmdDir, "dmd.conf"), ret))
							return ret;

						bool haveDRuntime = fs.exists(chainPath(dmdDir, "..", "..", "src",
								"druntime", "import"));
						bool havePhobos = fs.exists(chainPath(dmdDir, "..", "..", "src", "phobos"));
						if (haveDRuntime && havePhobos)
							return [
								buildNormalizedPath(dmdDir, "..", "..", "src", "druntime",
										"import"),
								buildNormalizedPath(dmdDir, "..", "..", "src", "phobos")
							];
						else if (haveDRuntime)
							return [
								buildNormalizedPath(dmdDir, "..", "..", "src", "druntime", "import")
							];
						else if (havePhobos)
							return [buildNormalizedPath(dmdDir, "..", "..", "src", "phobos")];
					}

					return [`C:\D\dmd2\src\druntime\import`, `C:\D\dmd2\src\phobos`];
				}
				else version (Posix)
				{
					string home = environment.get("HOME");
					if (home.length && fs.exists(chainPath(home, "dmd.conf"))
							&& parseDmdConfImports(buildPath(home, "dmd.conf"), ret))
						return ret;

					auto dmdPath = searchPathFor("dmd");
					if (dmdPath.length)
					{
						auto dmdDir = dirName(dmdPath);
						if (fs.exists(chainPath(dmdDir, "dmd.conf"))
								&& parseDmdConfImports(buildPath(dmdDir, "dmd.conf"), ret))
							return ret;
					}

					if (fs.exists("/etc/dmd.conf") && parseDmdConfImports("/etc/dmd.conf", ret))
						return ret;

					version (OSX)
						return [
							`/Library/D/dmd/src/druntime/import`, `/Library/D/dmd/src/phobos`
						];
					else
						return [
							`/usr/include/dmd/druntime/import`, `/usr/include/dmd/phobos`
						];
				}
				else
				{
					pragma(msg,
							__FILE__ ~ "(" ~ __LINE__
							~ "): Note: Unknown target OS. Please add default D stdlib path");
					return [];
				}
			}
			else
				return [p.str.userPath];
		}
	}

	string[] replace(Configuration newConfig)
	{
		string[] ret;
		ret ~= replaceSection!"d"(newConfig.d);
		ret ~= replaceSection!"dfmt"(newConfig.dfmt);
		ret ~= replaceSection!"dscanner"(newConfig.dscanner);
		ret ~= replaceSection!"editor"(newConfig.editor);
		ret ~= replaceSection!"git"(newConfig.git);
		return ret;
	}

	string[] replaceSection(string section : "d")(D newD)
	{
		auto ret = compare!"d."(d, newD);
		d = newD;
		return ret;
	}

	string[] replaceSection(string section : "dfmt")(DFmt newDfmt)
	{
		auto ret = compare!"dfmt."(dfmt, newDfmt);
		dfmt = newDfmt;
		return ret;
	}

	string[] replaceSection(string section : "dscanner")(DScanner newDscanner)
	{
		auto ret = compare!"dscanner."(dscanner, newDscanner);
		dscanner = newDscanner;
		return ret;
	}

	string[] replaceSection(string section : "editor")(Editor newEditor)
	{
		auto ret = compare!"editor."(editor, newEditor);
		editor = newEditor;
		return ret;
	}

	string[] replaceSection(string section : "git")(Git newGit)
	{
		auto ret = compare!"git."(git, newGit);
		git = newGit;
		return ret;
	}

	string[] replaceAllSections(JSONValue[] settings)
	{
		import painlessjson : fromJSON;

		assert(settings.length >= configurationSections.length);
		auto changed = appender!(string[]);
		static foreach (n, section; configurationSections)
			changed ~= this.replaceSection!section(settings[n].fromJSON!(configurationTypes[n]));
		return changed.data;
	}
}

Configuration parseConfiguration(JSONValue json)
{
	Configuration ret;
	if (json.type != JSONType.object)
	{
		error("Configuration is not an object!");
		return ret;
	}

	foreach (key, value; json.object)
	{
	SectionSwitch:
		switch (key)
		{
			static foreach (section; configurationSections)
			{
		case section:
				__traits(getMember, ret, section) = value.parseConfigurationSection!(
						typeof(__traits(getMember, ret, section)))(key);
				break SectionSwitch;
			}
		default:
			infof("Ignoring unknown configuration section '%s'", key);
			break;
		}
	}

	return ret;
}

T parseConfigurationSection(T)(JSONValue json, string sectionKey)
{
	import std.traits : FieldNameTuple;
	import painlessjson : fromJSON;

	T ret;
	if (json.type != JSONType.object)
	{
		error("Configuration is not an object!");
		return ret;
	}

	foreach (key, value; json.object)
	{
	ConfigSwitch:
		switch (key)
		{
			static foreach (member; FieldNameTuple!T)
			{
		case member:
				{
					alias U = typeof(__traits(getMember, ret, member));
					try
					{
						static if (__traits(compiles, { T t = null; }))
						{
							if (value.type == JSONType.null_)
							{
								__traits(getMember, ret, member) = null;
							}
							else
							{
								static if (is(U : string))
									__traits(getMember, ret, member) = cast(U) value.str;
								else
									__traits(getMember, ret, member) = value.fromJSON!U;
							}
						}
						else
						{
							if (value.type == JSONType.null_)
							{
								// ignore null value on non-nullable
							}
							else
							{
								static if (is(U : string))
									__traits(getMember, ret, member) = cast(U) value.str;
								else
									__traits(getMember, ret, member) = value.fromJSON!U;
							}
						}
					}
					catch (Exception e)
					{
						errorf("Skipping unparsable configuration '%s.%s' which was expected to be of type %s parsed from %s: %s",
								sectionKey, key, U.stringof, value.type, e.msg);
					}
					break ConfigSwitch;
				}
			}
		default:
			warningf("Ignoring unknown configuration section '%s.%s'", sectionKey, key);
			break;
		}
	}

	return ret;
}

struct Workspace
{
	WorkspaceFolder folder;
	Configuration config;
	bool initialized, disabled;
	string[string] startupErrorNotifications;
	bool selected;

	void startupError(string folder, string error)
	{
		if (folder !in startupErrorNotifications)
			startupErrorNotifications[folder] = "";
		string errors = startupErrorNotifications[folder];
		if (errors.length)
		{
			if (errors.endsWith(".", "\n\n"))
				startupErrorNotifications[folder] ~= " " ~ error;
			else if (errors.endsWith(". "))
				startupErrorNotifications[folder] ~= error;
			else
				startupErrorNotifications[folder] ~= "\n\n" ~ error;
		}
		else
			startupErrorNotifications[folder] = error;
	}

	string[] stdlibPath()
	{
		return config.stdlibPath(folder.uri.uriToFile);
	}

	auto describeState() const @property
	{
		static struct WorkspaceState
		{
			string uri, name;
			bool initialized;
			bool selected;
		}

		WorkspaceState state;
		state.uri = folder.uri;
		state.name = folder.name;
		state.initialized = initialized;
		state.selected = selected;
		return state;
	}
}

deprecated string workspaceRoot() @property
{
	return firstWorkspaceRootUri.uriToFile;
}

string selectedWorkspaceUri() @property
{
	foreach (ref workspace; workspaces)
		if (workspace.selected)
			return workspace.folder.uri;
	return firstWorkspaceRootUri;
}

string selectedWorkspaceRoot() @property
{
	return selectedWorkspaceUri.uriToFile;
}

string firstWorkspaceRootUri() @property
{
	return workspaces.length ? workspaces[0].folder.uri : "";
}

Workspace fallbackWorkspace;
Workspace[] workspaces;
ClientCapabilities capabilities;
RPCProcessor rpc;

size_t workspaceIndex(string uri)
{
	if (!uri.startsWith("file://"))
		throw new Exception("Passed a non file:// uri to workspace(uri): '" ~ uri ~ "'");
	size_t best = size_t.max;
	size_t bestLength = 0;
	foreach (i, ref workspace; workspaces)
	{
		if (workspace.folder.uri.length > bestLength
				&& uri.startsWith(workspace.folder.uri) && !workspace.disabled)
		{
			best = i;
			bestLength = workspace.folder.uri.length;
			if (uri.length == workspace.folder.uri.length) // startsWith + same length => same string
				return i;
		}
	}
	return best;
}

ref Workspace handleThings(ref Workspace workspace, string uri, bool userExecuted,
		string file = __FILE__, size_t line = __LINE__)
{
	if (userExecuted)
	{
		string f = uri.uriToFile;
		foreach (key, error; workspace.startupErrorNotifications)
		{
			if (f.startsWith(key))
			{
				//dfmt off
				debug
					rpc.window.showErrorMessage(
							error ~ "\n\nFile: " ~ file ~ ":" ~ line.to!string);
				else
					rpc.window.showErrorMessage(error);
				//dfmt on
				workspace.startupErrorNotifications.remove(key);
			}
		}

		bool notifyChange, changedOne;
		foreach (ref w; workspaces)
		{
			if (w.selected)
			{
				if (w.folder.uri != workspace.folder.uri)
					notifyChange = true;
				changedOne = true;
				w.selected = false;
			}
		}
		workspace.selected = true;
		if (notifyChange || !changedOne)
			rpc.notifyMethod("coded/changedSelectedWorkspace", workspace.describeState);
	}
	return workspace;
}

ref Workspace workspace(string uri, bool userExecuted = true,
		string file = __FILE__, size_t line = __LINE__)
{
	if (!uri.length)
		return fallbackWorkspace;

	auto best = workspaceIndex(uri);
	if (best == size_t.max)
		return bestWorkspaceByDependency(uri).handleThings(uri, userExecuted, file, line);
	return workspaces[best].handleThings(uri, userExecuted, file, line);
}

ref Workspace bestWorkspaceByDependency(string uri)
{
	size_t best = size_t.max;
	size_t bestLength;
	foreach (i, ref workspace; workspaces)
	{
		auto inst = backend.getInstance(workspace.folder.uri.uriToFile);
		if (!inst)
			continue;
		foreach (folder; chain(inst.importPaths, inst.importFiles, inst.stringImportPaths))
		{
			string folderUri = folder.uriFromFile;
			if (folderUri.length > bestLength && uri.startsWith(folderUri))
			{
				best = i;
				bestLength = folderUri.length;
				if (uri.length == folderUri.length) // startsWith + same length => same string
					return workspace;
			}
		}
	}
	if (best == size_t.max)
		return fallbackWorkspace;
	return workspaces[best];
}

ref Workspace selectedWorkspace()
{
	foreach (ref workspace; workspaces)
		if (workspace.selected)
			return workspace;
	return fallbackWorkspace;
}

WorkspaceD.Instance activeInstance;

string workspaceRootFor(string uri)
{
	return workspace(uri).folder.uri.uriToFile;
}

bool hasWorkspace(string uri)
{
	foreach (i, ref workspace; workspaces)
		if (uri.startsWith(workspace.folder.uri))
			return true;
	return false;
}

ref Configuration config(string uri, bool userExecuted = true,
		string file = __FILE__, size_t line = __LINE__)
out (result)
{
	trace("Config for ", uri, ": ", result);
}
do
{
	return workspace(uri, userExecuted, file, line).config;
}

ref Configuration firstConfig()
{
	if (!workspaces.length)
		throw new Exception("No config available");
	return workspaces[0].config;
}

DocumentUri uriFromFile(string file)
{
	import std.uri : encodeComponent;

	if (!isAbsolute(file))
		throw new Exception("Tried to pass relative path '" ~ file ~ "' to uriFromFile");
	file = file.buildNormalizedPath.replace("\\", "/");
	if (file.length == 0)
		return "";
	if (file[0] != '/')
		file = '/' ~ file; // always triple slash at start but never quad slash
	if (file.length >= 2 && file[0 .. 2] == "//") // Shares (\\share\bob) are different somehow
		file = file[2 .. $];
	return "file://" ~ file.encodeComponent.replace("%2F", "/");
}

string uriToFile(DocumentUri uri)
{
	import std.uri : decodeComponent;
	import std.string : startsWith;

	if (uri.startsWith("file://"))
	{
		string ret = uri["file://".length .. $].decodeComponent;
		if (ret.length >= 3 && ret[0] == '/' && ret[2] == ':')
			return ret[1 .. $].replace("/", "\\");
		else if (ret.length >= 1 && ret[0] != '/')
			return "\\\\" ~ ret.replace("/", "\\");
		return ret;
	}
	else
		return null;
}

@system unittest
{
	void testUri(string a, string b)
	{
		void assertEqual(A, B)(A a, B b)
		{
			import std.conv : to;

			assert(a == b, a.to!string ~ " is not equal to " ~ b.to!string);
		}

		assertEqual(a.uriFromFile, b);
		assertEqual(a, b.uriToFile);
		assertEqual(a.uriFromFile.uriToFile, a);
	}

	version (Windows)
	{
		// taken from vscode-uri
		testUri(`c:\test with %\path`, `file:///c%3A/test%20with%20%25/path`);
		testUri(`c:\test with %25\path`, `file:///c%3A/test%20with%20%2525/path`);
		testUri(`c:\test with %25\c#code`, `file:///c%3A/test%20with%20%2525/c%23code`);
		testUri(`\\shäres\path\c#\plugin.json`, `file://sh%C3%A4res/path/c%23/plugin.json`);
		testUri(`\\localhost\c$\GitDevelopment\express`, `file://localhost/c%24/GitDevelopment/express`);
	}
	else version (Posix)
	{
		testUri(`/home/pi/.bashrc`, `file:///home/pi/.bashrc`);
		testUri(`/home/pi/Development Projects/D-code`, `file:///home/pi/Development%20Projects/D-code`);
	}
}

string userPath(string path)
{
	return expandTilde(path);
}

string userPath(Configuration.Git git)
{
	// vscode may send null git path
	return git.path.length ? userPath(git.path) : "git";
}

DocumentUri uri(string scheme, string authority, string path, string query, string fragment)
{
	return scheme ~ "://" ~ (authority.length ? authority : "") ~ (path.length ? path
			: "/") ~ (query.length ? "?" ~ query : "") ~ (fragment.length ? "#" ~ fragment : "");
}

int toInt(JSONValue value)
{
	if (value.type == JSONType.uinteger)
		return cast(int) value.uinteger;
	else
		return cast(int) value.integer;
}

__gshared WorkspaceD backend;

/// Quick function to check if a package.json can not not be a dub package file.
/// Returns: false if fields are used which aren't usually used in dub but in nodejs.
bool seemsLikeDubJson(JSONValue packageJson)
{
	if ("main" in packageJson || "engines" in packageJson || "publisher" in packageJson
			|| "private" in packageJson || "devDependencies" in packageJson)
		return false;
	if ("name" !in packageJson)
		return false;
	return true;
}

/// Inserts a value into a sorted range. Inserts before equal elements.
/// Returns: the index where the value has been inserted.
size_t insertSorted(alias sort = "a<b", T)(ref T[] arr, T value)
{
	auto v = arr.binarySearch!sort(value);
	if (v < 0)
		v = ~v;
	arr.length++;
	for (ptrdiff_t i = cast(ptrdiff_t) arr.length - 1; i > v; i--)
		move(arr[i - 1], arr[i]);
	arr[v] = value;
	return v;
}

/// Finds a value in a sorted range and returns its index.
/// Returns: a bitwise invert of the first element bigger than value. Use `~ret` to turn it back.
ptrdiff_t binarySearch(alias sort = "a<b", T)(T[] arr, T value)
{
	auto sorted = assumeSorted!sort(arr).trisect(value);
	if (sorted[1].length)
		return cast(ptrdiff_t) sorted[0].length;
	else
		return ~cast(ptrdiff_t) sorted[0].length;
}

private string searchPathFor()(scope const(char)[] executable)
{
	auto path = environment.get("PATH");

	version (Posix)
		char separator = ':';
	else version (Windows)
		char separator = ';';
	else
		static assert(false, "No path separator character");

	foreach (dir; path.splitter(separator))
	{
		auto execPath = buildPath(dir, executable);
		if (fs.exists(execPath))
			return execPath;
	}

	return null;
}

bool parseDmdConfImports(R)(R path, out string[] paths)
{
	enum Region
	{
		none,
		env32,
		env64
	}

	Region match, current;

	foreach (line; io.File(path).byLine)
	{
		line = line.strip;
		if (!line.length)
			continue;

		if (line.sicmp("[Environment32]") == 0)
			current = Region.env32;
		else if (line.sicmp("[Environment64]") == 0)
			current = Region.env64;
		else if (line.startsWith("DFLAGS=") && current >= match)
		{
			version (Windows)
				paths = parseDflagsImports(line["DFLAGS=".length .. $].stripLeft, true);
			else
				paths = parseDflagsImports(line["DFLAGS=".length .. $].stripLeft, false);
			match = current;
		}
	}

	return match != Region.none || paths.length > 0;
}

string[] parseDflagsImports(scope const char[] options, bool windows)
{
	auto ret = appender!(string[]);
	size_t i = options.indexOf("-I");
	while (i != cast(size_t)-1)
	{
		if (i == 0 || options[i - 1] == '"' || options[i - 1] == '\'' || options[i - 1] == ' ')
		{
			dchar quote = i == 0 ? ' ' : options[i - 1];
			i += "-I".length;
			ret.put(parseArgumentWord(options, quote, i, windows));
		}
		else
			i += "-I".length;

		i = options.indexOf("-I", i);
	}
	return ret.data;
}

private string parseArgumentWord(const scope char[] data, dchar quote, ref size_t i, bool windows)
{
	bool allowEscapes = quote != '\'';
	bool inEscape;
	bool ending = quote == ' ';
	auto part = appender!string;
	while (i < data.length)
	{
		auto c = decode!(UseReplacementDchar.yes)(data, i);
		if (inEscape)
		{
			part.put(c);
			inEscape = false;
		}
		else if (ending)
		{
			// -I"abc"def
			// or
			// -I'abc'\''def'
			if (c.isWhite)
				break;
			else if (c == '\\' && !windows)
				inEscape = true;
			else if (c == '\'')
			{
				quote = c;
				allowEscapes = false;
				ending = false;
			}
			else if (c == '"')
			{
				quote = c;
				allowEscapes = true;
				ending = false;
			}
			else
				part.put(c);
		}
		else
		{
			if (c == quote)
				ending = true;
			else if (c == '\\' && allowEscapes && !windows)
				inEscape = true;
			else
				part.put(c);
		}
	}
	return part.data;
}

unittest
{
	void test(string input, string[] expect)
	{
		auto actual = parseDflagsImports(input, false);
		assert(actual == expect, actual.to!string ~ " != " ~ expect.to!string);
	}

	test(`a`, []);
	test(`-I`, [``]);
	test(`-Iabc`, [`abc`]);
	test(`-Iab\\cd -Ief`, [`ab\cd`, `ef`]);
	test(`-Iab\ cd -Ief`, [`ab cd`, `ef`]);
	test(`-I/usr/include/dmd/phobos -I/usr/include/dmd/druntime/import -L-L/usr/lib/x86_64-linux-gnu -L--export-dynamic -fPIC`,
			[`/usr/include/dmd/phobos`, `/usr/include/dmd/druntime/import`]);
	test(`-I/usr/include/dmd/phobos -L-L/usr/lib/x86_64-linux-gnu -I/usr/include/dmd/druntime/import -L--export-dynamic -fPIC`,
			[`/usr/include/dmd/phobos`, `/usr/include/dmd/druntime/import`]);
}

void prettyPrintStruct(alias printFunc, T, int line = __LINE__, string file = __FILE__,
		string funcName = __FUNCTION__, string prettyFuncName = __PRETTY_FUNCTION__,
		string moduleName = __MODULE__)(T value, string indent = "\t")
		if (is(T == struct))
{
	static foreach (i, member; T.tupleof)
	{
		{
			static if (is(typeof(member) == Optional!U, U))
			{
				if (value.tupleof[i].isNull)
				{
					printFunc!(line, file, funcName, prettyFuncName, moduleName)(indent,
							__traits(identifier, member), "?: <null>");
				}
				else
				{
					static if (is(U == struct))
					{
						printFunc!(line, file, funcName, prettyFuncName, moduleName)(indent,
								__traits(identifier, member), "?:");
						prettyPrintStruct!(printFunc, U, line, file, funcName, prettyFuncName, moduleName)(value.tupleof[i].get,
								indent ~ "\t");
					}
					else
					{
						printFunc!(line, file, funcName, prettyFuncName, moduleName)(indent,
								__traits(identifier, member), "?: ", value.tupleof[i].get);
					}
				}
			}
			else static if (is(typeof(member) == JSONValue))
			{
				printFunc!(line, file, funcName, prettyFuncName, moduleName)(indent,
						__traits(identifier, member), ": ", value.tupleof[i].toString());
			}
			else static if (is(typeof(member) == struct))
			{
				printFunc!(line, file, funcName, prettyFuncName, moduleName)(indent,
						__traits(identifier, member), ":");
				prettyPrintStruct!(printFunc, typeof(member), line, file, funcName,
						prettyFuncName, moduleName)(value.tupleof[i], indent ~ "\t");
			}
			else
				printFunc!(line, file, funcName, prettyFuncName, moduleName)(indent,
						__traits(identifier, member), ": ", value.tupleof[i]);
		}
	}
}
