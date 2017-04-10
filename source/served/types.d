module served.types;

public import served.protocol;
public import served.protoext;
public import served.textdocumentmanager;

import std.algorithm;
import std.array;
import std.json;
import std.path;

import served.jsonrpc;

struct protocolMethod
{
	string method;
}

struct protocolNotification
{
	string method;
}

enum IncludedFeatures = ["d"];

TextDocumentManager documents;

string[] compare(string prefix, T)(ref T a, ref T b)
{
	string[] changed;
	foreach (member; __traits(allMembers, T))
		if (__traits(getMember, a, member) != __traits(getMember, b, member))
			changed ~= prefix ~ member;
	return changed;
}

struct Configuration
{
	struct D
	{
		JSONValue stdlibPath = JSONValue("auto");
		string dcdClientPath = "dcd-client", dcdServerPath = "dcd-server";
		string dscannerPath = "dscanner";
		string dfmtPath = "dfmt";
		string dubPath = "dub";
		bool enableLinting = true;
		bool enableSDLLinting = true;
		bool enableDubLinting = true;
		bool enableAutoComplete = true;
		bool neverUseDub = false;
		string[] projectImportPaths;
		string dubConfiguration;
		string dubArchType;
		string dubBuildType;
		string dubCompiler;
		bool overrideDfmtEditorconfig = true;
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

	D d;
	DFmt dfmt;
	Editor editor;

	string[] stdlibPath()
	{
		auto p = d.stdlibPath;
		if (p.type == JSON_TYPE.STRING)
		{
			if (p.str == "auto")
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
							"source/served/types.d(83): Unknown target OS. Please add default D stdlib path");
					return [];
				}
			}
			else
				return [p.str];
		}
		else
			return p.array.map!"a.str".array;
	}

	string[] replace(Configuration newConfig)
	{
		auto ret = compare!"d."(d, newConfig.d) ~ compare!"dfmt."(dfmt,
				newConfig.dfmt) ~ compare!"editor."(editor, newConfig.editor);
		d = newConfig.d;
		dfmt = newConfig.dfmt;
		editor = newConfig.editor;
		return ret;
	}
}

Configuration config;
string workspaceRoot;
RPCProcessor rpc;

DocumentUri uriFromFile(string file)
{
	import std.uri : encode;

	version (Windows)
		enum absPrefix = "file:///"; // file:///c:/...
	else
		enum absPrefix = "file://";

	if (isAbsolute(file))
		return absPrefix ~ file.buildNormalizedPath.replace("\\", "/").encode;
	else
		return "file://" ~ buildNormalizedPath(workspaceRoot, file).replace("\\", "/").encode;
}

string uriToFile(DocumentUri uri)
{
	import std.uri;
	import std.string;

	version (Windows)
		if (uri.startsWith("file:///"))
			return uri["file:///".length .. $].decode;
	if (uri.startsWith("file://"))
		return uri["file://".length .. $].decode;
	else
		return null;
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
