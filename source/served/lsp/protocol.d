module served.lsp.protocol;

import std.conv;
import std.json;
import std.meta;
import std.traits;

import painlessjson;

struct Optional(T)
{
	bool isNull = true;
	T value;

	this(T val)
	{
		value = val;
		isNull = false;
	}

	this(U)(U val)
	{
		value = val;
		isNull = false;
	}

	this(typeof(null))
	{
		isNull = true;
	}

	void opAssign(typeof(null))
	{
		nullify();
	}

	void opAssign(T val)
	{
		isNull = false;
		value = val;
	}

	void opAssign(U)(U val)
	{
		isNull = false;
		value = val;
	}

	void nullify()
	{
		isNull = true;
		value = T.init;
	}

	string toString() const
	{
		if (isNull)
			return "null(" ~ T.stringof ~ ")";
		else
			return value.to!string;
	}

	const JSONValue _toJSON()
	{
		import painlessjson : toJSON;

		if (isNull)
			return JSONValue(null);
		else
			return value.toJSON;
	}

	static Optional!T _fromJSON(JSONValue val)
	{
		Optional!T ret;
		ret.isNull = false;
		ret.value = val.fromJSON!T;
		return ret;
	}

	ref inout(T) get() inout
	{
		return value;
	}

	alias value this;
}

mixin template StrictOptionalSerializer()
{
	const JSONValue _toJSON()
	{
		JSONValue[string] ret = this.defaultToJSON.object;
		foreach (member; __traits(allMembers, typeof(this)))
			static if (is(typeof(__traits(getMember, this, member)) == Optional!T, T))
			{
				static if (hasUDA!(__traits(getMember, this, member), SerializedName))
					string name = getUDAs!(__traits(getMember, this, member), SerializedName)[0].to;
				else static if (hasUDA!(__traits(getMember, this, member), SerializedToName))
					string name = getUDAs!(__traits(getMember, this, member), SerializedToName)[0].name;
				else
					string name = member;

				if (__traits(getMember, this, member).isNull)
					ret.remove(name);
			}
		return JSONValue(ret);
	}
}

Optional!T opt(T)(T val)
{
	return Optional!T(val);
}

struct ArrayOrSingle(T)
{
	T[] value;

	this(T val)
	{
		value = [val];
	}

	this(T[] val)
	{
		value = val;
	}

	void opAssign(T val)
	{
		value = [val];
	}

	void opAssign(T[] val)
	{
		value = val;
	}

	const JSONValue _toJSON()
	{
		if (value.length == 1)
			return value[0].toJSON;
		else
			return value.toJSON;
	}

	static ArrayOrSingle!T fromJSON(JSONValue val)
	{
		ArrayOrSingle!T ret;
		if (val.type == JSONType.array)
			ret.value = val.fromJSON!(T[]);
		else
			ret.value = [val.fromJSON!T];
		return ret;
	}

	alias value this;
}

struct RequestToken
{
	this(const(JSONValue)* val)
	{
		if (!val)
		{
			hasData = false;
			return;
		}
		hasData = true;
		if (val.type == JSONType.string)
		{
			isString = true;
			str = val.str;
		}
		else if (val.type == JSONType.integer)
		{
			isString = false;
			num = val.integer;
		}
		else
			throw new Exception("Invalid ID");
	}

	union
	{
		string str;
		long num;
	}

	bool hasData, isString;

	JSONValue toJSON()
	{
		JSONValue ret = null;
		if (!hasData)
			return ret;
		ret = isString ? JSONValue(str) : JSONValue(num);
		return ret;
	}

	JSONValue _toJSON()()
	{
		pragma(msg, "Attempted painlesstraits.toJSON on RequestToken");
	}

	void _fromJSON()(JSONValue val)
	{
		pragma(msg, "Attempted painlesstraits.fromJSON on RequestToken");
	}

	string toString()
	{
		return hasData ? (isString ? str : num.to!string) : "none";
	}

	static RequestToken random()
	{
		import std.uuid;

		JSONValue id = JSONValue(randomUUID.toString);
		return RequestToken(&id);
	}

	bool opEquals(RequestToken b) const
	{
		return isString == b.isString && (isString ? str == b.str : num == b.num);
	}
}

struct RequestMessage
{
	this(JSONValue val)
	{
		id = RequestToken("id" in val);
		method = val["method"].str;
		auto ptr = "params" in val;
		if (ptr)
			params = *ptr;
	}

	RequestToken id;
	string method;
	JSONValue params;

	bool isCancelRequest()
	{
		return method == "$/cancelRequest";
	}

	JSONValue toJSON()
	{
		auto ret = JSONValue([
				"jsonrpc": JSONValue("2.0"),
				"method": JSONValue(method)
				]);
		if (!params.isNull)
			ret["params"] = params;
		if (id.hasData)
			ret["id"] = id.toJSON;
		return ret;
	}
}

enum ErrorCode
{
	parseError = -32700,
	invalidRequest = -32600,
	methodNotFound = -32601,
	invalidParams = -32602,
	internalError = -32603,
	serverErrorStart = -32099,
	serverErrorEnd = -32000,
	serverNotInitialized = -32002,
	unknownErrorCode = -32001
}

enum MessageType
{
	error = 1,
	warning,
	info,
	log
}

struct ResponseError
{
	ErrorCode code;
	string message;
	JSONValue data;

	this(Throwable t)
	{
		code = ErrorCode.unknownErrorCode;
		message = t.msg;
		data = JSONValue(t.to!string);
	}

	this(ErrorCode c)
	{
		code = c;
		message = c.to!string;
	}

	this(ErrorCode c, string msg)
	{
		code = c;
		message = msg;
	}
}

class MethodException : Exception
{
	this(ResponseError error, string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc @safe
	{
		super(error.message, file, line);
		this.error = error;
	}

	ResponseError error;
}

struct ResponseMessage
{
	this(RequestToken id, JSONValue result)
	{
		this.id = id;
		this.result = result;
	}

	this(RequestToken id, ResponseError error)
	{
		this.id = id;
		this.error = error;
	}

	RequestToken id;
	Optional!JSONValue result;
	Optional!ResponseError error;
}

alias DocumentUri = string;

enum EolType
{
	cr,
	lf,
	crlf
}

string toString(EolType eol)
{
	final switch (eol)
	{
	case EolType.cr:
		return "\r";
	case EolType.lf:
		return "\n";
	case EolType.crlf:
		return "\r\n";
	}
}

struct Position
{
	/// Zero-based line & character offset (UTF-16 codepoints)
	uint line, character;
}

struct TextRange
{
	union
	{
		struct
		{
			Position start;
			Position end;
		}

		Position[2] range;
	}

	alias range this;

	this(Num)(Num startLine, Num startCol, Num endLine, Num endCol) if (isNumeric!Num)
	{
		this(Position(cast(uint) startLine, cast(uint) startCol),
				Position(cast(uint) endLine, cast(uint) endCol));
	}

	this(Position start, Position end)
	{
		this.start = start;
		this.end = end;
	}

	this(Position[2] range)
	{
		this.range = range;
	}

	this(Position pos)
	{
		this.start = pos;
		this.end = pos;
	}
}

struct Location
{
	DocumentUri uri;
	TextRange range;
}

struct Diagnostic
{
	TextRange range;
	DiagnosticSeverity severity;
	JSONValue code;
	string source;
	string message;
	Optional!(DiagnosticRelatedInformation[]) relatedInformation;
	Optional!(DiagnosticTag[]) tags;
}

struct DiagnosticRelatedInformation
{
	Location location;
	string message;
}

enum DiagnosticSeverity
{
	error = 1,
	warning,
	information,
	hint
}

enum DiagnosticTag
{
	unnecessary = 1,
	deprecated_
}

struct Command
{
	string title;
	string command;
	JSONValue[] arguments;
}

struct TextEdit
{
	TextRange range;
	string newText;
}

struct CreateFileOptions
{
	mixin StrictOptionalSerializer;

	Optional!bool overwrite;
	Optional!bool ignoreIfExists;
}

struct CreateFile
{
	mixin StrictOptionalSerializer;

	string uri;
	Optional!CreateFileOptions options;
	string kind = "create";
}

struct RenameFileOptions
{
	mixin StrictOptionalSerializer;

	Optional!bool overwrite;
	Optional!bool ignoreIfExists;
}

struct RenameFile
{
	mixin StrictOptionalSerializer;

	string oldUri;
	string newUri;
	Optional!RenameFileOptions options;
	string kind = "rename";
}

struct DeleteFileOptions
{
	mixin StrictOptionalSerializer;

	Optional!bool recursive;
	Optional!bool ignoreIfNotExists;
}

struct DeleteFile
{
	mixin StrictOptionalSerializer;

	string uri;
	Optional!DeleteFileOptions options;
	string kind = "delete";
}

struct TextDocumentEdit
{
	VersionedTextDocumentIdentifier textDocument;
	TextEdit[] edits;
}

alias TextEditCollection = TextEdit[];

struct WorkspaceEdit
{
	mixin StrictOptionalSerializer;

	TextEditCollection[DocumentUri] changes;

	Optional!JSONValue documentChanges;
}

struct TextDocumentIdentifier
{
	DocumentUri uri;
}

struct VersionedTextDocumentIdentifier
{
	DocumentUri uri;
	@SerializedName("version") long version_;
}

struct TextDocumentItem
{
	DocumentUri uri;
	string languageId;
	@SerializedName("version") long version_;
	string text;
}

struct TextDocumentPositionParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

struct DocumentFilter
{
	Optional!string language;
	Optional!string scheme;
	Optional!string pattern;
}

alias DocumentSelector = DocumentFilter[];

struct InitializeParams
{
	int processId;
	string rootPath;
	DocumentUri rootUri;
	JSONValue initializationOptions;
	ClientCapabilities capabilities;
	string trace = "off";
	WorkspaceFolder[] workspaceFolders;
}

struct DynamicRegistration
{
	mixin StrictOptionalSerializer;

	Optional!bool dynamicRegistration;
}

enum ResourceOperationKind : string
{
	create = "create",
	rename = "rename",
	delete_ = "delete"
}

enum FailureHandlingKind : string
{
	abort = "abort",
	transactional = "transactional",
	textOnlyTransactional = "textOnlyTransactional",
	undo = "undo"
}

struct WorkspaceEditClientCapabilities
{
	mixin StrictOptionalSerializer;

	Optional!bool documentChanges;
	Optional!(string[]) resourceOperations;
	Optional!string failureHandling;
}

struct WorkspaceClientCapabilities
{
	mixin StrictOptionalSerializer;

	bool applyEdit;
	Optional!WorkspaceEditClientCapabilities workspaceEdit;
	Optional!DynamicRegistration didChangeConfiguration;
	Optional!DynamicRegistration didChangeWatchedFiles;
	Optional!DynamicRegistration symbol;
	Optional!DynamicRegistration executeCommand;
	Optional!bool workspaceFolders;
	Optional!bool configuration;
}

struct TextDocumentClientCapabilities
{
	mixin StrictOptionalSerializer;

	struct SyncInfo
	{
		mixin StrictOptionalSerializer;

		Optional!bool dynamicRegistration;
		Optional!bool willSave;
		Optional!bool willSaveWaitUntil;
		Optional!bool didSave;
	}

	struct CompletionInfo
	{
		mixin StrictOptionalSerializer;

		struct CompletionItem
		{
			mixin StrictOptionalSerializer;

			Optional!bool snippetSupport;
			Optional!bool commitCharactersSupport;
			//Optional!(MarkupKind[]) documentationFormat;
			Optional!bool deprecatedSupport;
			Optional!bool preselectSupport;
		}

		struct CompletionItemKindSet
		{
			mixin StrictOptionalSerializer;

			// CompletionItemKind[]
			Optional!(int[]) valueSet;
		}

		Optional!bool dynamicRegistration;
		Optional!CompletionItem completionItem;
		Optional!CompletionItemKindSet completionItemKind;
		Optional!bool contextSupport;
	}

	struct SignatureHelpInfo
	{
		struct SignatureInformationInfo
		{
			struct ParameterInformationInfo
			{
				mixin StrictOptionalSerializer;

				Optional!bool labelOffsetSupport;
			}

			mixin StrictOptionalSerializer;

			// MarkupKind[]
			Optional!(string[]) documentationFormat;
			Optional!ParameterInformationInfo parameterInformation;
		}

		mixin StrictOptionalSerializer;

		Optional!bool dynamicRegistration;
		Optional!SignatureInformationInfo signatureInformation;

		@SerializeIgnore bool supportsLabelOffset() @property
		{
			if (signatureInformation.isNull || signatureInformation.parameterInformation.isNull
					|| signatureInformation.parameterInformation.labelOffsetSupport.isNull)
				return false;
			return signatureInformation.parameterInformation.labelOffsetSupport.get;
		}
	}

	struct DocumentSymbolInfo
	{
		mixin StrictOptionalSerializer;

		struct SymbolKindSet
		{
			mixin StrictOptionalSerializer;

			// SymbolKind[]
			Optional!(int[]) valueSet;
		}

		Optional!bool dynamicRegistration;
		Optional!SymbolKindSet symbolKind;
		Optional!bool hierarchicalDocumentSymbolSupport;
	}

	struct PublishDiagnosticsCap
	{
		mixin StrictOptionalSerializer;

		Optional!bool relatedInformation;
	}

	Optional!SyncInfo synchronization;
	Optional!CompletionInfo completion;
	Optional!DynamicRegistration hover;
	Optional!SignatureHelpInfo signatureHelp;
	Optional!DynamicRegistration references;
	Optional!DynamicRegistration documentHighlight;
	Optional!DocumentSymbolInfo documentSymbol;
	Optional!DynamicRegistration formatting;
	Optional!DynamicRegistration rangeFormatting;
	Optional!DynamicRegistration onTypeFormatting;
	Optional!DynamicRegistration definition;
	Optional!DynamicRegistration typeDefinition;
	Optional!DynamicRegistration implementation;
	Optional!DynamicRegistration codeAction;
	Optional!DynamicRegistration codeLens;
	Optional!DynamicRegistration documentLink;
	Optional!DynamicRegistration colorProvider;
	Optional!DynamicRegistration rename;
	Optional!PublishDiagnosticsCap publishDiagnostics;
}

struct ClientCapabilities
{
	Optional!WorkspaceClientCapabilities workspace;
	Optional!TextDocumentClientCapabilities textDocument;
	JSONValue experimental;
}

unittest
{
	string json = q{{
		"workspace": {
			"configuration": true
		}
	}};
	auto caps = json.parseJSON.fromJSON!ClientCapabilities;
	assert(caps.workspace.configuration);
}

struct InitializeResult
{
	ServerCapabilities capabilities;
}

struct InitializeError
{
	bool retry;
}

enum TextDocumentSyncKind
{
	none,
	full,
	incremental
}

struct CompletionOptions
{
	bool resolveProvider;
	string[] triggerCharacters;
}

struct SignatureHelpOptions
{
	string[] triggerCharacters;
}

struct CodeLensOptions
{
	bool resolveProvider;
}

struct DocumentOnTypeFormattingOptions
{
	mixin StrictOptionalSerializer;

	string firstTriggerCharacter;
	Optional!(string[]) moreTriggerCharacter;
}

struct DocumentLinkOptions
{
	bool resolveProvider;
}

struct ColorProviderOptions
{
}

struct ExecuteCommandOptions
{
	string[] commands;
}

struct SaveOptions
{
	bool includeText;
}

struct TextDocumentSyncOptions
{
	bool openClose;
	int change;
	bool willSave;
	bool willSaveWaitUntil;
	SaveOptions save;
}

struct ServerCapabilities
{
	mixin StrictOptionalSerializer;

	JSONValue textDocumentSync;
	bool hoverProvider;
	Optional!CompletionOptions completionProvider;
	Optional!SignatureHelpOptions signatureHelpProvider;
	bool definitionProvider;
	Optional!bool typeDefinitionProvider;
	Optional!bool implementationProvider;
	bool referencesProvider;
	bool documentHighlightProvider;
	bool documentSymbolProvider;
	bool workspaceSymbolProvider;
	bool codeActionProvider;
	Optional!CodeLensOptions codeLensProvider;
	bool documentFormattingProvider;
	bool documentRangeFormattingProvider;
	Optional!DocumentOnTypeFormattingOptions documentOnTypeFormattingProvider;
	bool renameProvider;
	Optional!DocumentLinkOptions documentLinkProvider;
	Optional!ColorProviderOptions colorProvider;
	Optional!ExecuteCommandOptions executeCommandProvider;
	Optional!ServerWorkspaceCapabilities workspace;
	JSONValue experimental;
}

struct ServerWorkspaceCapabilities
{
	mixin StrictOptionalSerializer;

	struct WorkspaceFolders
	{
		mixin StrictOptionalSerializer;

		Optional!bool supported;
		Optional!bool changeNotifications;
	}

	Optional!WorkspaceFolders workspaceFolders;
}

struct ShowMessageParams
{
	MessageType type;
	string message;
}

struct ShowMessageRequestParams
{
	mixin StrictOptionalSerializer;

	MessageType type;
	string message;
	Optional!(MessageActionItem[]) actions;
}

struct MessageActionItem
{
	string title;
}

struct LogMessageParams
{
	MessageType type;
	string message;
}

struct Registration
{
	string id;
	string method;
	JSONValue registerOptions;
}

struct RegistrationParams
{
	Registration[] registrations;
}

struct TextDocumentRegistrationOptions
{
	mixin StrictOptionalSerializer;

	Optional!DocumentSelector documentSelector;
}

struct Unregistration
{
	string id;
	string method;
}

struct UnregistrationParams
{
	Unregistration[] unregistrations;
}

struct DidChangeConfigurationParams
{
	JSONValue settings;
}

struct ConfigurationParams
{
	ConfigurationItem[] items;
}

struct ConfigurationItem
{
	mixin StrictOptionalSerializer;

	Optional!string scopeUri;
	Optional!string section;
}

struct DidOpenTextDocumentParams
{
	TextDocumentItem textDocument;
}

struct DidChangeTextDocumentParams
{
	VersionedTextDocumentIdentifier textDocument;
	TextDocumentContentChangeEvent[] contentChanges;
}

struct TextDocumentContentChangeEvent
{
	mixin StrictOptionalSerializer;

	Optional!TextRange range;
	Optional!int rangeLength;
	string text;
}

struct TextDocumentChangeRegistrationOptions
{
	mixin StrictOptionalSerializer;

	Optional!DocumentSelector documentSelector;
	TextDocumentSyncKind syncKind;
}

struct WillSaveTextDocumentParams
{
	TextDocumentIdentifier textDocument;
	TextDocumentSaveReason reason;
}

enum TextDocumentSaveReason
{
	manual = 1,
	afterDelay,
	focusOut
}

struct DidSaveTextDocumentParams
{
	mixin StrictOptionalSerializer;

	TextDocumentIdentifier textDocument;
	Optional!string text;
}

struct TextDocumentSaveRegistrationOptions
{
	mixin StrictOptionalSerializer;

	Optional!DocumentSelector documentSelector;
	bool includeText;
}

struct DidCloseTextDocumentParams
{
	TextDocumentIdentifier textDocument;
}

struct DidChangeWatchedFilesParams
{
	FileEvent[] changes;
}

struct FileEvent
{
	DocumentUri uri;
	FileChangeType type;
}

enum FileChangeType
{
	created = 1,
	changed,
	deleted
}

struct PublishDiagnosticsParams
{
	DocumentUri uri;
	Diagnostic[] diagnostics;
}

struct CompletionList
{
	bool isIncomplete;
	CompletionItem[] items;
}

enum InsertTextFormat
{
	plainText = 1,
	snippet
}

struct CompletionItem
{
	mixin StrictOptionalSerializer;

	string label;
	Optional!CompletionItemKind kind;
	Optional!string detail;
	Optional!MarkupContent documentation;
	@SerializedName("deprecated") Optional!bool deprecated_;
	Optional!bool preselect;
	Optional!string sortText;
	Optional!string filterText;
	Optional!string insertText;
	Optional!InsertTextFormat insertTextFormat;
	Optional!TextEdit textEdit;
	Optional!(TextEdit[]) additionalTextEdits;
	Optional!(string[]) commitCharacters;
	Optional!Command command;
	JSONValue data;
}

enum CompletionItemKind
{
	text = 1,
	method,
	function_,
	constructor,
	field,
	variable,
	class_,
	interface_,
	module_,
	property,
	unit,
	value,
	enum_,
	keyword,
	snippet,
	color,
	file,
	reference,
	folder,
	enumMember,
	constant,
	struct_,
	event,
	operator,
	typeParameter
}

struct CompletionRegistrationOptions
{
	Optional!DocumentSelector documentSelector;
	Optional!(string[]) triggerCharacters;
	bool resolveProvider;
}

struct Hover
{
	ArrayOrSingle!MarkedString contents;
	Optional!TextRange range;
}

struct MarkedString
{
	string value;
	string language;

	const JSONValue _toJSON()
	{
		if (!language.length)
			return JSONValue(value);
		else
			return JSONValue([
					"value": JSONValue(value),
					"language": JSONValue(language)
					]);
	}

	static MarkedString fromJSON(JSONValue val)
	{
		MarkedString ret;
		if (val.type == JSONType.string)
			ret.value = val.str;
		else
		{
			ret.value = val["value"].str;
			ret.language = val["language"].str;
		}
		return ret;
	}
}

enum MarkupKind : string
{
	plaintext = "plaintext",
	markdown = "markdown"
}

struct MarkupContent
{
	MarkupKind kind;
	string value;

	this(MarkupKind kind, string value)
	{
		this.kind = kind;
		this.value = value;
	}

	this(string text)
	{
		kind = MarkupKind.plaintext;
		value = text;
	}

	this(MarkedString[] markup)
	{
		kind = MarkupKind.markdown;
		foreach (block; markup)
		{
			if (block.language.length)
			{
				value ~= "```" ~ block.language ~ "\n";
				value ~= block.value;
				value ~= "```";
			}
			else
				value ~= block.value;
			value ~= "\n\n";
		}
	}
}

struct SignatureHelp
{
	SignatureInformation[] signatures;
	Optional!int activeSignature;
	Optional!int activeParameter;

	this(SignatureInformation[] signatures)
	{
		this.signatures = signatures;
	}

	this(SignatureInformation[] signatures, int activeSignature, int activeParameter)
	{
		this.signatures = signatures;
		this.activeSignature = activeSignature;
		this.activeParameter = activeParameter;
	}
}

struct SignatureInformation
{
	string label;
	Optional!MarkupContent documentation;
	Optional!(ParameterInformation[]) parameters;
}

struct ParameterInformation
{
	JSONValue label;
	Optional!MarkupContent documentation;
}

struct SignatureHelpRegistrationOptions
{
	Optional!DocumentSelector documentSelector;
	Optional!(string[]) triggerCharacters;
}

struct ReferenceParams
{
	TextDocumentIdentifier textDocument;
	Position position;
	ReferenceContext context;
}

struct ReferenceContext
{
	bool includeDeclaration;
}

struct DocumentHighlight
{
	TextRange range;
	Optional!DocumentHighlightKind kind;
}

enum DocumentHighlightKind
{
	text = 1,
	read,
	write
}

struct DocumentSymbolParams
{
	TextDocumentIdentifier textDocument;
}

struct SymbolInformation
{
	string name;
	SymbolKind kind;
	Location location;
	Optional!string containerName;
}

struct DocumentSymbol
{
	mixin StrictOptionalSerializer;

	string name;
	Optional!string detail;
	SymbolKind kind;
	@SerializedName("deprecated") Optional!bool deprecated_;
	TextRange range;
	TextRange selectionRange;
	DocumentSymbol[] children;
	@SerializeIgnore string parent;
}

enum SymbolKind
{
	file = 1,
	module_,
	namespace,
	package_,
	class_,
	method,
	property,
	field,
	constructor,
	enum_,
	interface_,
	function_,
	variable,
	constant,
	string,
	number,
	boolean,
	array,
	object,
	key,
	null_,
	enumMember,
	struct_,
	event,
	operator,
	typeParameter
}

struct WorkspaceSymbolParams
{
	string query;
}

struct CodeActionParams
{
	TextDocumentIdentifier textDocument;
	TextRange range;
	CodeActionContext context;
}

struct CodeActionContext
{
	Diagnostic[] diagnostics;
}

struct CodeLensParams
{
	TextDocumentIdentifier textDocument;
}

struct CodeLens
{
	TextRange range;
	Optional!Command command;
	JSONValue data;
}

struct CodeLensRegistrationOptions
{
	Optional!DocumentSelector documentSelector;
	bool resolveProvider;
}

struct DocumentLinkParams
{
	TextDocumentIdentifier textDocument;
}

struct DocumentLink
{
	TextRange range;
	DocumentUri target;
}

struct DocumentLinkRegistrationOptions
{
	Optional!DocumentSelector documentSelector;
	bool resolveProvider;
}

struct DocumentFormattingParams
{
	TextDocumentIdentifier textDocument;
	FormattingOptions options;
}

struct FormattingOptions
{
	int tabSize;
	bool insertSpaces;
	JSONValue data;
}

struct DocumentRangeFormattingParams
{
	TextDocumentIdentifier textDocument;
	TextRange range;
	FormattingOptions options;
}

struct DocumentOnTypeFormattingParams
{
	TextDocumentIdentifier textDocument;
	Position position;
	string ch;
	FormattingOptions options;
}

struct DocumentOnTypeFormattingRegistrationOptions
{
	Optional!DocumentSelector documentSelector;
	string firstTriggerCharacter;
	Optional!(string[]) moreTriggerCharacter;
}

struct RenameParams
{
	TextDocumentIdentifier textDocument;
	Position position;
	string newName;
}

struct ExecuteCommandParams
{
	string command;
	Optional!(JSONValue[]) arguments;
}

struct ExecuteCommandRegistrationOptions
{
	string[] commands;
}

struct ApplyWorkspaceEditParams
{
	WorkspaceEdit edit;
}

struct ApplyWorkspaceEditResponse
{
	bool applied;
}

struct WorkspaceFolder
{
	string uri;
	string name;
}

struct DidChangeWorkspaceFoldersParams
{
	WorkspaceFoldersChangeEvent event;
}

struct WorkspaceFoldersChangeEvent
{
	WorkspaceFolder[] added;
	WorkspaceFolder[] removed;
}
