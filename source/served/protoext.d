module served.protoext;

import served.protocol;

import std.json;
import painlessjson;

struct AddImportParams
{
	TextDocumentIdentifier textDocument;
	string name;
	int location;
	bool insertOutermost = true;
}

struct SortImportsParams
{
	TextDocumentIdentifier textDocument;
	int location;
}

struct ImplementMethodsParams
{
	TextDocumentIdentifier textDocument;
	int location;
}

struct UpdateSettingParams
{
	string section;
	JSONValue value;
	bool global;
}

struct DubDependency
{
	string name;
	@SerializedName("version")
	string version_;
	string path;
	string description;
	string homepage;
	const(string)[] authors;
	string copyright;
	string license;
	const(string)[] subPackages;
	bool hasDependencies;
	bool root;
}

struct DubConvertRequest
{
	TextDocumentIdentifier textDocument;
	string newFormat;
}

struct InstallRequest
{
	string name;
	@SerializedName("version")
	string version_;
}

struct UpdateRequest
{
	string name;
	@SerializedName("version")
	string version_;
}

struct UninstallRequest
{
	string name;
}

struct Task
{
	enum Group : string
	{
		clean = "clean",
		build = "build",
		rebuild = "rebuild",
		test = "test"
	}

	JSONValue definition;
	@SerializedName("scope")
	string scope_;
	string[] exec;
	string name;
	bool isBackground;
	string source;
	Group group;
	string[] problemMatchers;
}

struct SymbolInformationEx
{
	string name;
	SymbolKind kind;
	Location location;
	string containerName;
	@SerializedName("deprecated") bool deprecated_;
	TextRange range;
	TextRange selectionRange;

	SymbolInformation downcast()
	{
		SymbolInformation ret;
		static foreach (member; __traits(allMembers, SymbolInformationEx))
			static if (__traits(hasMember, SymbolInformation, member))
				__traits(getMember, ret, member) = __traits(getMember, this, member);
		return ret;
	}
}
