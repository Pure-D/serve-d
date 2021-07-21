module served.types;

public import served.backend.lazy_workspaced : LazyWorkspaceD;
public import served.lsp.protocol;
public import served.lsp.protoext;
public import served.lsp.textdocumentmanager;
public import served.lsp.uri;
public import served.utils.events;

static import served.extension;

import served.serverbase;
mixin LanguageServerRouter!(served.extension) lspRouter;

import core.time : MonoTime;

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.experimental.logger;
import std.json;
import std.meta;
import std.path;
import std.range;
import std.string;

import fs = std.file;
import io = std.stdio;

import workspaced.api;

deprecated("import stdlib_detect directly")
public import served.utils.stdlib_detect : parseDmdConfImports, parseDflagsImports;

enum IncludedFeatures = ["d", "workspaces"];

__gshared MonoTime startupTime;

alias documents = lspRouter.documents;
alias rpc = lspRouter.rpc;

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
		bool enableCoverageDecoration = true;
		bool enableGCProfilerDecorations = true;
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
		string manyProjectsAction = ManyProjectsAction.ask;
		int manyProjectsThreshold = 6;
		string lintOnFileOpen = "project";
		bool dietContextCompletion = false;
		bool generateModuleNames = true;
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
		bool spaceBeforeFunctionParameters = false;
		bool singleTemplateConstraintIndent = false;
		bool spaceBeforeAAColon = false;
		bool keepLineBreaks = true;
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
				import served.utils.stdlib_detect;

				return autoDetectStdlibPaths(cwd);
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

ref Workspace handleThings(return ref Workspace workspace, string uri, bool userExecuted,
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

WorkspaceD.Instance _activeInstance;

WorkspaceD.Instance activeInstance(WorkspaceD.Instance value) @property
{
	trace("Setting active instance to ", value ? value.cwd : "<null>", ".");
	return _activeInstance = value;
}

WorkspaceD.Instance activeInstance() @property
{
	return _activeInstance;
}

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

string userPath(string path)
{
	return expandTilde(path);
}

string userPath(Configuration.Git git)
{
	// vscode may send null git path
	return git.path.length ? userPath(git.path) : "git";
}

int toInt(JSONValue value)
{
	if (value.type == JSONType.uinteger)
		return cast(int) value.uinteger;
	else
		return cast(int) value.integer;
}

__gshared LazyWorkspaceD backend;

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
