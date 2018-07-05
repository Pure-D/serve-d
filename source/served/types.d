module served.types;

public import served.protocol;
public import served.protoext;
public import served.textdocumentmanager;

import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.meta;
import std.path;
import std.range;

import workspaced.api;

import served.jsonrpc;

struct protocolMethod
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
	string[] changed;
	foreach (member; __traits(allMembers, T))
		if (__traits(getMember, a, member) != __traits(getMember, b, member))
			changed ~= prefix ~ member;
	return changed;
}

alias configurationTypes = AliasSeq!(Configuration.D, Configuration.DFmt,
		Configuration.Editor, Configuration.Git);
static immutable string[] configurationSections = ["d", "dfmt", "editor", "git"];

struct Configuration
{
	struct D
	{
		JSONValue stdlibPath = JSONValue("auto");
		string dcdClientPath = "dcd-client", dcdServerPath = "dcd-server";
		string dscannerPath = "dscanner";
		string dfmtPath = "dfmt";
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
		bool aggressiveUpdate = true;
		bool argumentSnippets = false;
		bool scanAllFolders = true;
		string[] disabledRootGlobs;
		string[] extraRoots;
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

	struct Editor
	{
		int[] rulers;
	}

	struct Git
	{
		string path = "git";
	}

	D d;
	DFmt dfmt;
	Editor editor;
	Git git;

	string[] stdlibPath()
	{
		auto p = d.stdlibPath;
		if (p.type == JSON_TYPE.ARRAY)
			return p.array.map!"a.str".array;
		else
		{
			if (p.type != JSON_TYPE.STRING || p.str == "auto")
			{
				version (Windows)
					return [`C:\D\dmd2\src\druntime\import`, `C:\D\dmd2\src\phobos`];
				else version (OSX)
					return [`/Library/D/dmd/src/druntime/import`, `/Library/D/dmd/src/phobos`];
				else version (Posix)
					return [`/usr/include/dmd/druntime/import`, `/usr/include/dmd/phobos`];
				else
				{
					pragma(msg,
							__FILE__ ~ "(" ~ __LINE__
							~ "): Note: Unknown target OS. Please add default D stdlib path");
					return [];
				}
			}
			else
				return [p.str];
		}
	}

	string[] replace(Configuration newConfig)
	{
		string[] ret;
		ret ~= replaceSection!"d"(newConfig.d);
		ret ~= replaceSection!"dfmt"(newConfig.dfmt);
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
}

struct Workspace
{
	WorkspaceFolder folder;
	Configuration config;
	bool initialized, disabled;
	string[string] startupErrorNotifications;

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
}

deprecated string workspaceRoot() @property
{
	return firstWorkspaceRootUri.uriToFile;
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

ref Workspace handleThings(ref Workspace workspace, string uri, bool triggerErrors,
		string file = __FILE__, size_t line = __LINE__)
{
	if (triggerErrors)
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
	}
	return workspace;
}

ref Workspace workspace(string uri, bool triggerErrors = true,
		string file = __FILE__, size_t line = __LINE__)
{
	auto best = workspaceIndex(uri);
	if (best == size_t.max)
		return bestWorkspaceByDependency(uri).handleThings(uri, triggerErrors, file, line);
	return workspaces[best].handleThings(uri, triggerErrors, file, line);
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

ref Configuration config(string uri, bool triggerErrors = true,
		string file = __FILE__, size_t line = __LINE__)
{
	return workspace(uri, triggerErrors, file, line).config;
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

	testUri(`/home/pi/.bashrc`, `file:///home/pi/.bashrc`);
	// taken from vscode-uri
	testUri(`c:\test with %\path`, `file:///c%3A/test%20with%20%25/path`);
	testUri(`c:\test with %25\path`, `file:///c%3A/test%20with%20%2525/path`);
	testUri(`c:\test with %25\c#code`, `file:///c%3A/test%20with%20%2525/c%23code`);
	testUri(`\\shäres\path\c#\plugin.json`, `file://sh%C3%A4res/path/c%23/plugin.json`);
	testUri(`\\localhost\c$\GitDevelopment\express`, `file://localhost/c%24/GitDevelopment/express`);
}

DocumentUri uri(string scheme, string authority, string path, string query, string fragment)
{
	return scheme ~ "://" ~ (authority.length ? authority : "") ~ (path.length ? path
			: "/") ~ (query.length ? "?" ~ query : "") ~ (fragment.length ? "#" ~ fragment : "");
}

int toInt(JSONValue value)
{
	if (value.type == JSON_TYPE.UINTEGER)
		return cast(int) value.uinteger;
	else
		return cast(int) value.integer;
}

WorkspaceD backend;

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
