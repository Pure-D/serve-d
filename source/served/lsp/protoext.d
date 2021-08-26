module served.lsp.protoext;

import served.lsp.protocol;

import painlessjson;
import std.json;

struct AddImportParams
{
	/// Text document to look in
	TextDocumentIdentifier textDocument;
	/// The name of the import to add
	string name;
	/// Location of cursor as standard offset
	int location;
	/// if `false`, the import will get added to the innermost block
	bool insertOutermost = true;
}

struct SortImportsParams
{
	/// Text document to look in
	TextDocumentIdentifier textDocument;
	/// Location of cursor as standard offset
	int location;
}

struct ImplementMethodsParams
{
	/// Text document to look in
	TextDocumentIdentifier textDocument;
	/// Location of cursor as standard offset
	int location;
}

struct UpdateSettingParams
{
	/// The configuration section to update in (e.g. "d" or "dfmt")
	string section;
	/// The value to set the configuration value to
	JSONValue value;
	/// `true` if this is a configuration change across all instances and not just the active one
	bool global;
}

/// Represents a dependency of a dub project
struct DubDependency
{
	/// The name of this package
	string name;
	/// The installed version of this dependency or null if it isn't downloaded/installed yet
	@SerializedName("version")
	string version_;
	/// Path to the directory in which the package resides or null if it's not stored in the local file system.
	string path;
	/** Description as given in dub package file */
	string description;
	/// Homepage as given in dub package file
	string homepage;
	/// Authors as given in dub package file
	const(string)[] authors;
	/// Copyright as given in dub package file
	string copyright;
	/// License as given in dub package file
	string license;
	/// List of the names of subPackages as defined in the package 
	const(string)[] subPackages;
	/// `true` if this dependency has other dependencies
	bool hasDependencies;
	/// `true` if no package name was given and thus this dependency is a root dependency of the active project.
	bool root;
}

/// Parameters for a dub recipe conversion call
struct DubConvertRequest
{
	/// Text document to look in
	TextDocumentIdentifier textDocument;
	/// The format to convert the dub recipe to. (json, sdl)
	string newFormat;
}

///
struct InstallRequest
{
	/// Name of the dub dependency
	string name;
	/// Version to install in the dub recipe file
	@SerializedName("version")
	string version_;
}

///
struct UpdateRequest
{
	/// Name of the dub dependency
	string name;
	/// Version to install in the dub recipe file
	@SerializedName("version")
	string version_;
}

///
struct UninstallRequest
{
	/// Name of the dub dependency
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

struct DocumentSymbolParamsEx
{
	// LSP field
	TextDocumentIdentifier textDocument;
	bool verbose;

	this(DocumentSymbolParams params)
	{
		textDocument = params.textDocument;
	}

	this(TextDocumentIdentifier textDocument, bool verbose)
	{
		this.textDocument = textDocument;
		this.verbose = verbose;
	}
}

/// special serve-d internal symbol kinds
enum SymbolKindEx
{
	none = 0,
	/// set for unittests
	test,
	/// `debug = X` specification
	debugSpec,
	/// `version = X` specification
	versionSpec,
	/// `static this()`
	staticCtor,
	/// `shared static this()`
	sharedStaticCtor,
	/// `static ~this()`
	staticDtor,
	/// `shared static ~this()`
	sharedStaticDtor,
	/// `this(this)` in structs & classes
	postblit
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
	SymbolKindEx extendedType;
	string detail;

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
	/// true if this snippet shouldn't be formatted before inserting.
	bool unformatted;
}

/// Parameters to pass when updating dub imports
struct UpdateImportsParams
{
	/// set this to false to not emit progress updates for the UI
	bool reportProgress = true;
}

/// An ini section of the dscanner.ini which is written in form [name]
struct DScannerIniSection
{
	/// A textual human readable description of the section
	string description;
	/// The name of the section as written in the ini
	string name;
	/// Features which are children of this section
	DScannerIniFeature[] features;
}

/// A single feature in a dscanner.ini which can be turned on/off
struct DScannerIniFeature
{
	/// A textual human readable description of the value
	string description;
	/// The name of the value
	string name;
	/// disabled | enabled | skip-unittest
	string enabled;
}

struct UnittestProject
{
	/// Workspace uri which may or may not map to an actual workspace folder
	/// but rather to some folder inside one.
	DocumentUri workspaceUri;

	/// Package name if available
	string name;

	/// List of modules, sorted by moduleName
	UnittestModule[] modules;

	/// `true` if the project still needs to be opened to be loaded.
	bool needsLoad;
}

struct UnittestModule
{
	string moduleName;
	DocumentUri uri;
	UnittestInfo[] tests;
}

struct UnittestInfo
{
	string id, name;
	string containerName;
	TextRange range;
}

struct RescanTestsParams
{
	string uri = null;
}
