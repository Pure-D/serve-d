module served.types;

public import served.backend.lazy_workspaced : LazyWorkspaceD;
public import served.lsp.protocol;
public import served.lsp.protoext;
public import served.lsp.textdocumentmanager;
public import served.lsp.uri;
public import served.utils.events;

static import served.extension;

import served.serverbase;

/// These are kind-of minimum values for a bunch of "killer" tests in libdparse
debug
	enum requiredLibdparsePageCount = 128; // = 1 MiB stack per fiber
else // release builds are more optimized with stack usage
	enum requiredLibdparsePageCount = 32; // = 256 KiB stack per fiber

static immutable LanguageServerConfig lsConfig = {
	defaultPages: requiredLibdparsePageCount,
	productName: "serve-d"
};

mixin LanguageServerRouter!(served.extension, lsConfig) lspRouter;

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

import mir.serde;

import workspaced.api;

deprecated("import stdlib_detect directly")
public import served.utils.stdlib_detect : parseDmdConfImports, parseDflagsImports;

enum IncludedFeatures = ["d", "workspaces"];

__gshared MonoTime startupTime;

alias documents = lspRouter.documents;
alias rpc = lspRouter.rpc;

enum ManyProjectsAction : string
{
	ask = "ask",
	skip = "skip",
	load = "load"
}

// alias to avoid name clashing
alias UserConfiguration = Configuration;
@serdeIgnoreUnexpectedKeys
struct Configuration
{
@serdeIgnoreUnexpectedKeys:
@serdeOptional:

	struct D
	{
		@serdeOptional:
		JsonValue stdlibPath = JsonValue("auto");
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
		@serdeOptional:
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
		bool singleIndent = true;
	}

	struct DScanner
	{
		@serdeOptional:
		string[] ignoredKeys;
	}

	struct Editor
	{
		@serdeOptional:
		int[] rulers;
		int tabSize;
	}

	struct Git
	{
		@serdeOptional:
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
		if (p.kind == JsonValue.Kind.array)
			return p.get!(JsonValue[]).map!(a => a.get!string.userPath).array;
		else
		{
			if (p.kind != JsonValue.Kind.string || p.get!string == "auto")
			{
				import served.utils.stdlib_detect;

				return autoDetectStdlibPaths(cwd, d.dubCompiler);
			}
			else
				return [p.get!string.userPath];
		}
	}
}

struct Workspace
{
	WorkspaceFolder folder;
	bool initialized, disabled;
	string[string] startupErrorNotifications;
	bool selected;
	bool useGlobalConfig;

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

	ref inout(Configuration) config() inout
	{
		auto cfg = folder.uri in served.extension.perWorkspaceConfigurationStore;
		if (!cfg || useGlobalConfig)
			cfg = served.extension.globalConfiguration;
		return cast(inout) cfg.config;
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

int toInt(JsonValue value)
{
	return cast(int)value.get!long;
}

__gshared LazyWorkspaceD backend;

/// Quick function to check if a package.json can not not be a dub package file.
/// Returns: false if fields are used which aren't usually used in dub but in nodejs.
bool seemsLikeDubJson(string json)
{
	if (!json.looksLikeJsonObject)
		return false;
	auto packageJson = json.parseKeySlices!("main", "engines", "publisher",
		"private_", "devDependencies", "name");
	if (packageJson.main.length
		|| packageJson.engines.length
		|| packageJson.publisher.length
		|| packageJson.private_.length
		|| packageJson.devDependencies.length)
		return false;
	if (!packageJson.name.length)
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
	{{
		static if (isVariant!(typeof(member)))
		{
			static if (is(typeof(member).AllowedTypes[0] == void))
			{
				// is optional
				value.tupleof[i].match!(
					() {
						printFunc!(line, file, funcName, prettyFuncName, moduleName)(indent,
								__traits(identifier, member), "?: <null>");
					},
					(val) {
						static if (is(typeof(val) == struct))
						{
							printFunc!(line, file, funcName, prettyFuncName, moduleName)(indent,
									__traits(identifier, member), "?:");
							prettyPrintStruct!(printFunc, typeof(val), line, file, funcName, prettyFuncName, moduleName)(
									val, indent ~ "\t");
						}
						else
						{
							printFunc!(line, file, funcName, prettyFuncName, moduleName)(
									indent, __traits(identifier, member), "?: ", val);
						}
					}
				);
			}
			else
			{
				value.tupleof[i].match!(
					(val) {
						static if (is(typeof(val) == struct))
						{
							printFunc!(line, file, funcName, prettyFuncName, moduleName)(indent,
									__traits(identifier, member), ":");
							prettyPrintStruct!(printFunc, typeof(val), line, file, funcName, prettyFuncName, moduleName)(
									val, indent ~ "\t");
						}
						else
						{
							printFunc!(line, file, funcName, prettyFuncName, moduleName)(
									indent, __traits(identifier, member), ": ", val);
						}
					}
				);
			}
		}
		else static if (is(typeof(member) == JsonValue))
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
	}}
}

/// Event called when all components have been registered but no workspaces have
/// been setup yet.
/// Signature: `()`
enum onRegisteredComponents;

/// Event called when a project is available but not intended to be loaded yet.
/// Should not access any components, otherwise it will force a load, but only
/// show hints in the UI. When it's accessed and actually being loaded the
/// events `onAddingProject` and `onAddedProject` will be emitted.
/// Signature: `(WorkspaceD.Instance, string dir, string uri)`
enum onProjectAvailable;

/// Event called when a new workspaced instance is created. Called before dub or
/// fsworkspace is loaded.
/// Signature: `(WorkspaceD.Instance, string dir, string uri)`
enum onAddingProject;

/// Event called when a new project root is finished setting up. Called when all
/// components are loaded. DCD is loaded but not yet started at this point.
/// Signature: `(WorkspaceD.Instance, string dir, string rootFolderUri)`
enum onAddedProject;
