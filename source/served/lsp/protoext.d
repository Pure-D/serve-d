module served.lsp.protoext;

import served.lsp.protocol;
import served.lsp.textdocumentmanager;

import workspaced.api : CodeReplacement;

import mir.serde;

@serdeIgnoreUnexpectedKeys:

struct AddImportParams
{
	/// Text document to look in
	TextDocumentIdentifier textDocument;
	/// The name of the import to add
	string name;
	/// Location of cursor as standard offset
	int location;
	/// if `false`, the import will get added to the innermost block
	@serdeOptional bool insertOutermost = true;
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
	JsonValue value;
	/// `true` if this is a configuration change across all instances and not just the active one
	bool global;
}

/// Represents a dependency of a dub project
struct DubDependency
{
	/// The name of this package
	string name;
	/// `true` if this dependency failed to load.
	bool failed;
	/// The installed version of this dependency or null if it isn't downloaded/installed yet
	@serdeKeys("version")
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
struct SimpleTextDocumentIdentifierParams
{
	///
	TextDocumentIdentifier textDocument;
}

///
struct InstallRequest
{
	/// Name of the dub dependency
	string name;
	/// Version to install in the dub recipe file
	@serdeKeys("version")
	string version_;
}

///
struct UpdateRequest
{
	/// Name of the dub dependency
	string name;
	/// Version to install in the dub recipe file
	@serdeKeys("version")
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
	@serdeEnumProxy!string
	enum Group : string
	{
		clean = "clean",
		build = "build",
		rebuild = "rebuild",
		test = "test"
	}

	/// the default JSON task
	JsonValue definition;
	/// global | workspace | uri of workspace folder
	@serdeKeys("scope")
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

	this(DocumentSymbolParams params, bool verbose)
	{
		textDocument = params.textDocument;
		this.verbose = verbose;
	}

	this(TextDocumentIdentifier textDocument, bool verbose)
	{
		this.textDocument = textDocument;
		this.verbose = verbose;
	}
}

/// special serve-d internal symbol kinds
@serdeEnumProxy!int
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
	@serdeOptional Optional!(SymbolTag[]) tags;
	Location location;
	string containerName;
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
	@serdeOptional string plain;
	/// true if this snippet shouldn't be formatted before inserting.
	@serdeOptional bool unformatted;
	/// List of imports that should get imported with this snippet. (done in resolveComplete)
	@serdeOptional string[] imports;
}

/// Parameters to pass when updating dub imports
struct UpdateImportsParams
{
	/// set this to false to not emit progress updates for the UI
	@serdeOptional bool reportProgress = true;
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

/// Parameters for served/listArchTypes
struct ListArchTypesParams
{
	/// If true, return ArchTypeInfo[] with meanings instead of string[]
	@serdeOptional bool withMeaning;
}

/// Returned by served/listArchTypes if request was sent with
/// `withMeaning: true` request parameter.
struct ArchTypeInfo
{
	/// The value to use with a switchArchType call / the value DUB uses.
	string value;
	/// If not null, show this string in the UI rather than value.
	string label;
}

///
@serdeFallbackStruct
struct ArchType
{
	/// Value to pass into other calls
	string value;
	/// UI label override or null if none
	string label;
}

/// Converts the given workspace-d CodeReplacement to an LSP TextEdit
TextEdit toTextEdit(CodeReplacement replacement, scope const ref Document d)
{
	size_t lastIndex;
	Position lastPosition;

	auto startPos = d.nextPositionBytes(lastPosition, lastIndex, replacement.range[0]);
	auto endPos = d.nextPositionBytes(lastPosition, lastIndex, replacement.range[1]);

	return TextEdit([startPos, endPos], replacement.content);
}

///
@serdeFallbackStruct
struct ServedInfoParams
{
@serdeOptional:
	bool includeConfig;
	bool includeIndex;
}

///
@serdeFallbackStruct
struct ServedInfoResponse
{
	import served.types;

	/// Same as in the initialized response.
	ServerInfo serverInfo;

	/// Only included if `ServedInfoParams.includeConfig` is true.
	@serdeOptional Optional!Configuration currentConfiguration;

	/// Only included if `ServedInfoParams.includeIndex` is true.
	/// Key: module, Value: modules that depend on the (key) module.
	/// This is only the module index for the active workspace.
	@serdeOptional Optional!(string[][string]) moduleIndex;

	/// Describes the global workspace.
	typeof(Workspace.init.describeState()) globalWorkspace;

	/// Describes all available workspaces.
	typeof(Workspace.init.describeState())[] workspaces;

	/// First index inside the `workspaces` array sent along this value, where
	/// `selected` is set to true, or -1 for global workspace.
	int selectedWorkspaceIndex;
}

/// Mixin template that puts in a value called "value" of type `T`. Puts in a
/// custom deserializer that allows this struct to be both deserialized from a
/// full struct (if a struct has been sent) or any other value, directly getting
/// assigned to the `T value;` member.
///
/// This means `T` must not be anything that deserializes from a struct, as that
/// branch will never be called.
mixin template SingleValueParams(T, string valueName = "value")
if (!is(T == struct) && !is(T == Dummy[string], Dummy))
{
	import mir.ion.exception;
	import mir.ion.value;

	T _implicitValue;

	alias _implicitValue this;

	mixin("alias " ~ valueName ~ " = _implicitValue;");

	@safe pure scope
	IonException deserializeFromIon(scope const char[][] symbolTable, IonDescribedValue fullValue)
	{
		import mir.deser.ion : deserializeIon;
		import mir.ion.type_code : IonTypeCode;

		if (fullValue.descriptor.type == IonTypeCode.struct_)
		{
			auto struct_ = fullValue.get!(IonStruct).withSymbols(symbolTable);

			bool hasValue = false;

			foreach (error, key, value; struct_)
			{
				if (error)
					return error.ionException;

			Switch:
				switch (key)
				{
				case valueName:
					hasValue = true;
					_implicitValue = deserializeIon!(typeof(_implicitValue))(
						symbolTable, value);
					break Switch;

					static foreach (i, member; typeof(this).tupleof)
					{
						static if (__traits(identifier, member) != valueName)
						{
						case __traits(identifier, member):
							this.tupleof[i] = deserializeIon!(typeof(member))(
								symbolTable, value);
							break Switch;
						}
					}
				default:
					break;
				}
			}

			if (!hasValue)
				return new IonException(
					"Missing required `{\"value\":...}` parameter or must pass "
					~ "value as RPC array `[value]`.");

			return null;
		}
		else
		{
			_implicitValue = deserializeIon!T(symbolTable, fullValue);
			return null;
		}
	}
}

/// Used in `served/switchConfig`
struct SwitchConfigParams
{
	mixin SingleValueParams!string;
}

unittest
{
	import std.exception;

	assert(deserializeJson!SwitchConfigParams(`{"value":"foo"}`).value == "foo");
	assert(deserializeJson!SwitchConfigParams(`{"value":"foo","x":"y"}`).value == "foo");
	assertThrown(deserializeJson!SwitchConfigParams(`{"x":"y"}`));
	assert(deserializeJson!SwitchConfigParams(`"foo"`).value == "foo");
	assertThrown(deserializeJson!SwitchConfigParams(`4`).value);
}

/// Used in `served/switchArchType`
struct SwitchArchTypeParams
{
	mixin SingleValueParams!string;
}

/// Used in `served/switchBuildType`
struct SwitchBuildTypeParams
{
	mixin SingleValueParams!string;
}

/// Used in `served/switchCompiler`
struct SwitchCompilerParams
{
	mixin SingleValueParams!string;
}

/// Used in `served/listDependencies`
struct ListDependenciesParams
{
	mixin SingleValueParams!(string, "packageName");
}

/// Sent with `coded/skippedLoads`
struct SkippedLoadsNotification
{
	/// List of folder file paths
	string[] roots;
}
