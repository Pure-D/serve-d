module served.protoext;

import served.protocol;

import painlessjson;
import std.json;

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

	/// the default JSON task
	JSONValue definition;
	/// global | workspace | uri of workspace folder
	@SerializedName("scope")
	string scope_;
	/// command to execute
	string[] exec;
	/// name of the task
	string name;
	/// true if this is a background task without shown console
	bool isBackground;
	/// Task source extension name
	string source;
	/// clean | build | rebuild | test
	Group group;
	/// problem matchers to use
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

struct AddDependencySnippetParams
{
	string[] requiredDependencies;
	SerializablePlainSnippet snippet;
}

struct SerializablePlainSnippet
{
	/// Grammar scopes in which to complete this snippet. Maps to workspaced.com.snippets:SnippetLevel
	int[] levels;
	/// Shortcut to type for this snippet
	string shortcut;
	/// Label for this snippet.
	string title;
	/// Text with interactive snippet locations to insert assuming global indentation.
	string snippet;
	/// Markdown documentation for this snippet
	string documentation;
	/// Plain text to insert assuming global level indentation. Optional if snippet is a simple string only using plain variables and snippet locations.
	string plain;
}
