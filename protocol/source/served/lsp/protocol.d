/**
Implements the various LSP type definitions

Standards: LSP v3.16 https://microsoft.github.io/language-server-protocol/specifications/specification-3-16/
*/
module served.lsp.protocol;

import std.conv;
import std.meta;
import std.traits;

import mir.serde;
import mir.deser : serdeProxyCast;

public import mir.algebraic : Variant, isVariant, match, Nullable;

public import served.lsp.jsonops;

version (unittest)
	import std.exception;

private enum getJsonKey(T, string member) = ({
	enum keys = getUDAs!(__traits(getMember, T, member), serdeKeys);
	static if (keys.length)
	{
		static assert(keys.length == 1);
		assert(keys[0].keys.length == 1);
		return keys[0].keys[0];
	}
	else
	{
		return member;
	}
})();

enum getRequiredKeys(T) = ({
	import std.algorithm : sort;
	string[] ret;
	static foreach (member; serdeFinalProxyDeserializableMembers!T)
	{
		static if (!hasUDA!(__traits(getMember, T, member), serdeOptional))
			ret ~= getJsonKey!(T, member);
	}
	ret.sort!"a<b";
	return ret;
})();

@serdeFallbackStruct
@serdeProxy!JsonValue
struct StructVariant(AllowedTypes...)
if (AllowedTypes.length > 0)
{
	import mir.ion.exception;
	import mir.ion.value;

	import std.algorithm;
	import std.array;

	enum isAllowedType(T) = AllowedTypes.length == 0
		|| staticIndexOf!(Unqual!T, AllowedTypes) != -1;

	enum commonKeys = setIntersection(staticMap!(getRequiredKeys, AllowedTypes)).array;

	private static bool valueMatchesType(T)(IonStructWithSymbols struct_)
	{
		enum requiredKeys = getRequiredKeys!T;
		bool[requiredKeys.length] hasRequired;
		foreach (error, key, value; struct_)
		{
			Switch: switch (key)
			{
				static foreach (member; serdeFinalProxyDeserializableMembers!T)
				{
				case getJsonKey!(T, member):
					static if (!hasUDA!(__traits(getMember, T, member), serdeOptional))
					{
						enum idx = requiredKeys.countUntil(member);
						hasRequired[idx] = true;
					}
					break Switch;
				}
				default:
					break;
			}
		}

		static foreach (i; 0 .. hasRequired.length)
			if (!hasRequired[i])
				return false;
		return true;
	}

	static string mismatchMessage(T)(IonStructWithSymbols struct_)
	{
		string reasons;
		enum requiredKeys = getRequiredKeys!T;
		bool[requiredKeys.length] hasRequired;
		foreach (error, key, value; struct_)
		{
			Switch: switch (key)
			{
				static foreach (member; serdeFinalProxyDeserializableMembers!T)
				{
				case getJsonKey!(T, member):
					static if (!hasUDA!(__traits(getMember, T, member), serdeOptional))
					{
						enum idx = requiredKeys.countUntil(member);
						hasRequired[idx] = true;
					}
					break Switch;
				}
				default:
					break;
			}
		}

		static foreach (i; 0 .. hasRequired.length)
			if (!hasRequired[i])
				reasons ~= "missing required key " ~ requiredKeys[i] ~ "\n";
		return reasons.length ? reasons[0 .. $ - 1] : null;
	}

	Variant!AllowedTypes value;
	alias value this;

	this(Variant!AllowedTypes v)
	{
		value = v;
	}

	this(T)(T v)
	if (isAllowedType!T)
	{
		value = v;
	}

	ref typeof(this) opAssign(T)(T rhs)
	{
		static if (is(T : typeof(this)))
			value = rhs.value;
		else static if (isAllowedType!T)
			value = rhs;
		else
			static assert(false, "unsupported assignment of type " ~ T.stringof ~ " to " ~ typeof(this).stringof);
		return this;
	}

	void serialize(S)(scope ref S serializer) const
	{
		import mir.ser : serializeValue;

		serializeValue(serializer, value);
	}

	/**
	Returns: error msg if any
	*/
	@safe pure scope
	IonException deserializeFromIon(scope const char[][] symbolTable, IonDescribedValue value)
	{
		import mir.deser.ion : deserializeIon;
		import mir.ion.type_code : IonTypeCode;

		if (value.descriptor.type != IonTypeCode.struct_)
			return ionException(IonErrorCode.expectedStructValue);

		auto struct_ = value.get!(IonStruct).withSymbols(symbolTable);

		static if (commonKeys.length > 0)
		{
			bool[commonKeys.length] hasRequired;

			foreach (error, key, value; struct_)
			{
				if (error)
					return error.ionException;

			Switch:
				switch (key)
				{
					static foreach (i, member; commonKeys)
					{
				case member:
						hasRequired[i] = true;
						break Switch;
					}
				default:
					break;
				}
			}

			foreach (i, has; hasRequired)
				if (!has)
					return new IonException({
						string reason;
						foreach (i, has; hasRequired)
							if (!has)
								reason ~= "\nrequired common key '" ~ commonKeys[i] ~ "' is missing";
						return "ion value is not compatible with StructVariant with types " ~ AllowedTypes.stringof ~ reason;
					}());
		}

		static foreach (T; AllowedTypes)
			if (valueMatchesType!T(struct_))
				{
				this.value = deserializeIon!T(symbolTable, value);
				return null;
			}

		return new IonException({
			string reason;
			static foreach (T; AllowedTypes)
				reason ~= "\n\t" ~ T.stringof ~ ": " ~ mismatchMessage!T(struct_);
			return "ion value is not compatible with StructVariant with types " ~ AllowedTypes.stringof ~ ":" ~ reason;
		}());
	}

	bool tryExtract(T)(out T ret)
	{
		return value.match!(
			(T exact) { ret = exact; return true; },
			(other) {
				bool success = true;
				static foreach (key; __traits(allMembers, T))
				{
					static if (__traits(hasMember, other, key))
						__traits(getMember, ret, key) = __traits(getMember, other, key);
					else
						success = false;
				}
				if (!success)
					ret = T.init;
				return success;
			}
		);
	}

	T extract(T)() const
	if (isAllowedType!T)
	{
		return value.match!(
			(T exact) => exact,
			(other) {
				T ret;
				static foreach (key; __traits(allMembers, T))
				{
					static if (__traits(hasMember, other, key))
						__traits(getMember, ret, key) = __traits(getMember, other, key);
					else
						throw new Exception("can't extract " ~ T.stringof ~ " from effective " ~ (Unqual!(typeof(other))).stringof);
				}
				return ret;
			}
		);
	}
}

///
unittest
{
	@serdeIgnoreUnexpectedKeys
	struct Named
	{
		string name;
	}

	@serdeIgnoreUnexpectedKeys
	struct Person
	{
		string name;
		int age;
	}

	@serdeIgnoreUnexpectedKeys
	struct Place
	{
		string name;
		double lat, lon;
	}

	StructVariant!(Named, Person, Place) var = Person("Bob", 32);

	assert(var.serializeJson == `{"name":"Bob","age":32}`);

	Named extractedNamed;
	Person extractedPerson;
	Place extractedPlace;
	assert(var.tryExtract!Named(extractedNamed));//, var.mismatchMessage!Named(var.value));
	assert(var.tryExtract!Person(extractedPerson));//, var.mismatchMessage!Person(var.value));
	assert(!var.tryExtract!Place(extractedPlace));//, var.mismatchMessage!Place(var.value));

	try
	{
		var.extract!Place();
		assert(false);
	}
	catch (Exception e)
	{
		// assert(e.msg == "missing required key lat\nmissing required key lon", e.msg);
		assert(e.msg == "can't extract Place from effective Person", e.msg);
	}

	assert(extractedNamed.name == "Bob");
	assert(extractedPerson == Person("Bob", 32));
	assert(extractedPlace is Place.init);

	var = `{"name":"new name"}`.deserializeJson!(typeof(var));
	assert(var.extract!Named.name == "new name");
	assert(!var.tryExtract!Person(extractedPerson));
	assert(!var.tryExtract!Place(extractedPlace));

	assert(var.extract!Named.name == "new name");
	assertThrown({
		var = `{"nam":"name"}`.deserializeJson!(typeof(var));
	}());
	assert(var.extract!Named.name == "new name");

	assertThrown({
		var = `"hello"`.deserializeJson!(typeof(var));
	}());
}

unittest
{
	@serdeIgnoreUnexpectedKeys
	struct Person
	{
		string name;
		int age;
	}

	@serdeIgnoreUnexpectedKeys
	struct Place
	{
		string name;
		double lat, lon;
	}

	StructVariant!(Person, Place) var = Person("Bob", 32);

	assert(var.serializeJson == `{"name":"Bob","age":32}`);

	Person extractedPerson;
	Place extractedPlace;
	assert(var.tryExtract!Person(extractedPerson));//, var.mismatchMessage!Person(var.value));
	assert(!var.tryExtract!Place(extractedPlace));//, var.mismatchMessage!Place(var.value));

	assert(extractedPerson == Person("Bob", 32));
	assert(extractedPlace is Place.init);

	var = `{"name": "new name", "lat": 0, "lon": 1.5}`.deserializeJson!(typeof(var));

	assert(!var.tryExtract!Person(extractedPerson));//, var.mismatchMessage!Person(var.value));
	assert(var.tryExtract!Place(extractedPlace));//, var.mismatchMessage!Place(var.value));

	assert(extractedPerson is Person.init);
	assert(extractedPlace == Place("new name", 0, 1.5));

	assertThrown({
		var = `{"name":"broken name"}`.deserializeJson!(typeof(var));
	}());
	assert(var.extract!Place.name == "new name");

	var = `{"name":"Alice","age":64}`.deserializeJson!(typeof(var));
	assert(var.extract!Person == Person("Alice", 64));
}

struct AllowedMethods
{
	immutable string[] methods;
}

AllowedMethods allowedMethods(immutable string[] methods...)
{
	return AllowedMethods(methods.idup);
}

alias Optional(T) = Variant!(void, T);
alias OptionalJsonValue = Variant!(void, JsonValue);
template TypeFromOptional(T)
{
	alias Reduced = T.AllowedTypes;
	static assert(Reduced.length == 2, "got optional without exactly a single type: " ~ T.AllowedTypes.stringof);
	static assert(is(Reduced[0] == void), "got non-optional variant: " ~ T.AllowedTypes.stringof);
	alias TypeFromOptional = Reduced[1];
}

struct NullableOptional(T)
{
	import mir.ion.exception;
	import mir.ion.value;

	bool isSet = false;
	Nullable!T embed;

	this(T value)
	{
		isSet = true;
		embed = value;
	}

	this(typeof(null))
	{
		isSet = true;
		embed = null;
	}

	void unset()
	{
		isSet = false;
	}

	auto opAssign(T value)
	{
		isSet = true;
		embed = value;
		return this;
	}

	auto opAssign(typeof(null))
	{
		isSet = true;
		embed = null;
		return this;
	}

	bool serdeIgnoreOut() const @safe
	{
		return !isSet;
	}

	auto get() inout @safe
	{
		assert(isSet, "attempted to .get on an unset value");
		return embed;
	}

	// and use custom serializer to serialize as int
	void serialize(S)(scope ref S serializer) const
	{
		import mir.ser : serializeValue;

		assert(isSet, "attempted to serialize unset value");

		if (embed.isNull)
			serializer.putValue(null);
		else
			serializeValue(serializer, embed.get);
	}

	@trusted pure scope
	IonException deserializeFromIon(scope const char[][] symbolTable, IonDescribedValue value)
	{
		import mir.deser.ion: deserializeIon;
		import mir.ion.type_code : IonTypeCode;

		isSet = true;
		if (value == null)
			embed = null;
		else
			embed = deserializeIon!T(symbolTable, value);
		return null;
	}
}

pragma(inline, true)
bool isNone(T)(T v)
if (isVariant!T)
{
	return v._is!void;
}

///
pragma(inline, true)
auto deref(T)(scope return inout T v)
if (isVariant!T)
{
	return v.match!(
		() {
			throw new Exception("Attempted to get unset " ~ T.stringof);
			return assert(false); // changes return type to bottom_t
		},
		ret => ret
	);
}

/// ditto
pragma(inline, true)
JsonValue deref(scope return inout OptionalJsonValue v)
{
	if (v._is!void)
		throw new Exception("Attempted to get unset JsonValue");
	return v.get!JsonValue;
}

/// Returns the deref value from this optional or TypeFromOptional!T.init if
/// set to none.
pragma(inline, true)
TypeFromOptional!T orDefault(T, U)(scope return T v, lazy U defaultValue = TypeFromOptional!T.init)
if (isVariant!T)
{
	if (v._is!void)
		return defaultValue;
	else
		return v.get!(TypeFromOptional!T);
}

///
unittest
{
	static assert(is(TypeFromOptional!OptionalJsonValue == JsonValue));
	OptionalJsonValue someJson;
	assert(someJson.orDefault == JsonValue.init);
	someJson = JsonValue(5);
	assert(someJson.orDefault == JsonValue(5));

	static assert(is(TypeFromOptional!(Optional!int) == int));
	Optional!int someInt;
	assert(someInt.orDefault == 0);
	someInt = 5;
	assert(someInt.orDefault == 5);
}

///
pragma(inline, true)
T expect(T, ST)(ST v)
if (isVariant!ST)
{
	return v.match!(
		() {
			if (false) return T.init;
			throw new Exception("Attempted to get unset Optional!" ~ T.stringof);
		},
		(T val) => val,
		(v) {
			if (false) return T.init;
			throw new Exception("Attempted to get " ~ T.stringof ~ " from Variant of type " ~ typeof(v).stringof);
		}
	);
}

///
pragma(inline, true)
Optional!T opt(T)(T val)
{
	return Optional!T(val);
}

unittest
{
	Optional!int optInt;
	Optional!string optString1;
	Optional!string optString2;

	assert(optInt.isNone);
	assert(optString1.isNone);
	assert(optString2.isNone);

	optInt = 4;
	optString1 = null;
	optString2 = "hello";

	assert(!optInt.isNone);
	assert(!optString1.isNone);
	assert(!optString2.isNone);

	assert(optInt.deref == 4);
	assert(optString1.deref == null);
	assert(optString2.deref == "hello");

	assert(optInt.expect!int == 4);
	assert(optString1.expect!string == null);
	assert(optString2.expect!string == "hello");

	assertThrown(optInt.expect!string);
	assertThrown(optString1.expect!int);

	optInt = typeof(optInt)._void;
	optString1 = typeof(optString1)._void;
	optString2 = typeof(optString2)._void;

	assert(optInt.isNone);
	assert(optString1.isNone);
	assert(optString2.isNone);

	assertThrown(optInt.deref);
	assertThrown(optInt.expect!int);
	assertThrown(optString1.deref);
	assertThrown(optString1.expect!string);
}

@serdeIgnoreUnexpectedKeys:

///
alias ArrayOrSingle(T) = Variant!(T[], T);

///
@serdeFallbackStruct
struct RequiredValueSet(T)
{
	T[] valueSet;
}

///
@serdeFallbackStruct
struct OptionalValueSet(T)
{
	@serdeOptional Optional!(T[]) valueSet;
}

unittest
{
	auto single = ArrayOrSingle!Location(Location("file:///foo.d", TextRange(4, 2, 4, 8)));
	auto array = ArrayOrSingle!Location([Location("file:///foo.d", TextRange(4, 2, 4, 8)), Location("file:///bar.d", TextRange(14, 1, 14, 9))]);

	foreach (v; [single, array])
	{
		assert(deserializeJson!(ArrayOrSingle!Location)(v.serializeJson) == v);
	}
}

///
@serdeProxy!(typeof(RequestToken.value))
@serdeFallbackStruct
struct RequestToken
{
	Variant!(typeof(null), long, string) value;
	alias value this;

	this(T)(T v)
	{
		value = typeof(value)(v);
	}

	ref typeof(this) opAssign(T)(T rhs)
	{
		static if (is(T : typeof(this)))
			value = rhs.value;
		else
			value = rhs;
		return this;
	}

	/// Simply counts up using a global counter, wrapping around at int.max.
	static RequestToken next()
	{
		import core.atomic : atomicOp;

		static shared uint counter = 0;

		// uint overflows at 32 bits, we use a bitmask to further narrow this
		// down to 31 bits, which should be safe to handle by _any_ LSP client.
		//
		// no need to represent this in the uint counter, because overflow at 32
		// bit is basically the same thing we simulate here with the bitmask.
		uint ourValue = atomicOp!"+="(counter, 1)
			& 0x7FFF_FFFFu;

		return RequestToken(ourValue);
	}

	deprecated alias random = randomLong;

	static RequestToken randomLong()
	{
		import std.random : uniform;

		// Lua LSP clients (e.g. vim-lspconfig) aren't playing well with large numbers.
		// we simply don't go over int.max to support any sensible implementation here.
		enum long maxSafeInt = int.max;

		return RequestToken(uniform(0L, maxSafeInt));
	}

	static RequestToken randomString()
	{
		version (unittest)
			char[16] buffer; // make sure uninitialized buffers are caught in tests
		else
			char[16] buffer = void;

		randomSerializedString(buffer);
		return RequestToken(buffer[1 .. $ - 1].idup);
	}

	deprecated alias randomSerialized = randomSerializedString;

	static void randomSerializedString(char[] buffer)
	in(buffer.length > 2)
	{
		import std.random : uniform;

		static immutable letters = `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz`;

		buffer[0] = '"';
		for (int i = 1; i < buffer.length; i++)
			buffer[i] = letters[uniform(0, $)];
		buffer[$ - 1] = '"';
	}

	deprecated alias randomAndSerialized = randomAndSerializedString;

	static RequestToken randomAndSerializedString(char[] buffer)
	{
		randomSerializedString(buffer);
		return RequestToken(buffer[1 .. $ - 1].idup);
	}
}

unittest
{
	assert(deserializeJson!RequestToken(`"hello"`) == RequestToken("hello"));
	assert(deserializeJson!RequestToken(`4000`) == RequestToken(4000));
	assert(deserializeJson!RequestToken(`null`) == RequestToken(null));

	assert(`"hello"` == RequestToken("hello").serializeJson);
	assert(`4000` == RequestToken(4000).serializeJson);
	assert(`null` == RequestToken(null).serializeJson);

	auto tok = RequestToken.randomString();
	auto other = RequestToken.randomString();
	assert(tok.value.get!string.length > 10);
	assert(tok.value.get!string[0 .. 5] != tok.value.get!string[5 .. 10]);
	assert(tok.value.get!string != other.value.get!string);

	char[16] buf;
	tok = RequestToken.randomAndSerializedString(buf[]);
	assert(buf[0] == '"');
	assert(buf[$ - 1] == '"');
	assert(buf[1 .. $ - 1] == tok.value.get!string);

	other = "hello";
	assert(other.get!string == "hello");

	other = 6;
	assert(other.get!long == 6);
}

///
struct RequestMessage
{
	///
	@serdeOptional Optional!RequestToken id;
	///
	string jsonrpc = "2.0";
	///
	string method;
	/// Optional parameters to this method. Must be either null (omitted), array
	/// (positional parameters) or object. (named parameters)
	@serdeOptional OptionalJsonValue params;
}

///
struct RequestMessageRaw
{
	///
	@serdeOptional Optional!RequestToken id;
	///
	string jsonrpc = "2.0";
	///
	string method;
	/// Optional parameters to this method. Must be either empty string
	/// (omitted), or array (positional parameters) or object JSON string.
	/// (named parameters)
	string paramsJson;

	/// Formats this request message into `RequestMessage({method}: {json})`
	string toString() const @safe pure
	{
		return text("RequestMessage(", method, ": ", paramsJson, ")");
	}

	/// Descriptive name for this request/notification
	string fiberName() const @safe pure
	{
		return id.isNone
			? "Notification: " ~ method
			: "Request#" ~ id.deref.toString ~ ": " ~ method;
	}
}

///
@serdeEnumProxy!int
enum ErrorCode
{
	/// Invalid JSON was received by the server.
	/// An error occurred on the server while parsing the JSON text.
	parseError = -32700,
	/// The JSON sent is not a valid Request object.
	invalidRequest = -32600,
	/// The method does not exist / is not available.
	methodNotFound = -32601,
	/// Invalid method parameter(s).
	invalidParams = -32602,
	/// Internal JSON-RPC error.
	internalError = -32603,
	/// Range start reserved for implementation-defined server-errors.
	serverErrorStart = -32099,
	/// Range end reserved for implementation-defined server-errors.
	serverErrorEnd = -32000,
	/// serve-d specific error: received method before server was fully
	/// initialized.
	serverNotInitialized = -32002,
	///
	unknownErrorCode = -32001
}


///
@serdeFallbackStruct
struct ResponseError
{
	/// A Number that indicates the error type that occurred.
	ErrorCode code;
	/// A String providing a short description of the error.
	/// The message SHOULD be limited to a concise single sentence.
	string message;
	/// A Primitive or Structured value that contains additional information
	/// about the error.
	/// This may be omitted.
	/// The value of this member is defined by the Server (e.g. detailed error
	/// information, nested errors etc.).
	@serdeOptional OptionalJsonValue data;

	this(Throwable t)
	{
		code = ErrorCode.unknownErrorCode;
		message = t.msg;
		data = JsonValue(t.toString);
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

///
struct ResponseMessage
{
	this(RequestToken id, JsonValue result)
	{
		this.id = id;
		this.result = result;
	}

	this(RequestToken id, ResponseError error)
	{
		this.id = id;
		this.error = error;
	}

	this(typeof(null) id, JsonValue result)
	{
		this.id = null;
		this.result = result;
	}

	this(typeof(null) id, ResponseError error)
	{
		this.id = null;
		this.error = error;
	}

	///
	RequestToken id;
	///
	@serdeOptional OptionalJsonValue result;
	///
	@serdeOptional Optional!ResponseError error;
}

unittest
{
	ResponseMessage res = ResponseMessage(RequestToken("id"),
		ResponseError(ErrorCode.invalidRequest, "invalid request"));

	string buf;
	buf ~= `{"jsonrpc":"2.0"`;
	if (!res.id.isNull)
	{
		buf ~= `,"id":`;
		buf ~= res.id.serializeJson;
	}

	if (!res.result.isNone)
	{
		buf ~= `,"result":`;
		buf ~= res.result.serializeJson;
	}

	if (!res.error.isNone)
	{
		buf ~= `,"error":`;
		buf ~= res.error.serializeJson;
	}

	buf ~= `}`;

	assert(buf == `{"jsonrpc":"2.0","id":"id","error":{"code":-32600,"message":"invalid request"}}`);
}

///
struct ResponseMessageRaw
{
	///
	RequestToken id;
	/// empty string/null if not set, otherwise JSON string of result
	string resultJson;
	///
	@serdeOptional Optional!ResponseError error;

	/// Formats this request message into `ResponseMessage({id}: {json/error})`
	string toString() const @safe
	{
		if (error.isNone)
			return text("ResponseMessage(", id, ": ", resultJson, ")");
		else
			return text("ResponseMessage(", id, ": ", error.deref, ")");
	}

	static ResponseMessageRaw deserialize(scope const(char)[] json)
	in (json.looksLikeJsonObject)
	{
		auto slices = json.parseKeySlices!("id", "result", "error", "method", "params");

		auto tok = slices.id.deserializeJson!RequestToken;
		ResponseMessageRaw ret;
		ret.id = tok;
		auto res = slices.result;
		auto err = slices.error;
		if (res.length)
			ret.resultJson = res.idup;
		if (err.length)
			ret.error = err.deserializeJson!ResponseError;
		return ret;
	}
}

alias DocumentUri = string;

@serdeFallbackStruct
@allowedMethods("window/showMessage")
struct ShowMessageParams
{
	MessageType type;
	string message;
}

@serdeEnumProxy!int
enum MessageType
{
	error = 1,
	warning,
	info,
	log
}

@serdeFallbackStruct
struct ShowMessageRequestClientCapabilities
{
	@serdeFallbackStruct
	@serdeIgnoreUnexpectedKeys
	static struct MessageActionItemCapabilities
	{
		@serdeOptional Optional!bool additionalPropertiesSupport;
	}

	@serdeOptional Optional!MessageActionItemCapabilities messageActionItem;
}

@serdeFallbackStruct
@allowedMethods("window/showMessageRequest")
struct ShowMessageRequestParams
{
	MessageType type;
	string message;
	@serdeOptional Optional!(MessageActionItem[]) actions;
}

@serdeFallbackStruct
struct MessageActionItem
{
	string title;
}

@serdeFallbackStruct
struct ShowDocumentClientCapabilities
{
	bool support;
}

@serdeFallbackStruct
@allowedMethods("window/showDocument")
struct ShowDocumentParams
{
	DocumentUri uri;
	@serdeOptional Optional!bool external;
	@serdeOptional Optional!bool takeFocus;
	@serdeOptional Optional!TextRange selection;
}

@serdeFallbackStruct
struct ShowDocumentResult
{
	bool success;
}

@serdeFallbackStruct
@allowedMethods("window/logMessage")
struct LogMessageParams
{
	MessageType type;
	string message;
}

alias ProgressToken = Variant!(int, string);

@serdeFallbackStruct
@allowedMethods("window/workDoneProgress/create")
struct WorkDoneProgressCreateParams
{
	ProgressToken token;
}

@serdeFallbackStruct
@allowedMethods("window/workDoneProgress/cancel")
struct WorkDoneProgressCancelParams
{
	ProgressToken token;
}

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

@serdeFallbackStruct
struct Position
{
	/// Zero-based line & character offset (UTF-16 codepoints)
	uint line, character;

	int opCmp(const Position other) const
	{
		if (line < other.line)
			return -1;
		if (line > other.line)
			return 1;
		if (character < other.character)
			return -1;
		if (character > other.character)
			return 1;
		return 0;
	}
}

unittest
{
	foreach (v; [
		Position.init,
		Position(10),
		Position(10, 10),
		Position(uint.max - 1)
	])
		assert(deserializeJson!Position(v.serializeJson()) == v);
}

private struct SerializableTextRange
{
	Position start;
	Position end;

	this(Position start, Position end) @safe pure nothrow @nogc
	{
		this.start = start;
		this.end = end;
	}

	this(TextRange r) @safe pure nothrow @nogc
	{
		start = r.start;
		end = r.end;
	}
}

@serdeProxy!SerializableTextRange
@serdeFallbackStruct
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

	enum all = TextRange(0, 0, int.max, int.max); // int.max ought to be enough

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

	/// Returns: true if this range contains the position or the position is at
	/// the edges of this range.
	bool contains(Position position)
	{
		int minLine = start.line;
		int minCol = start.character;
		int maxLine = end.line;
		int maxCol = end.character;

		return !(position.line < minLine || position.line > maxLine
			|| (position.line == minLine && position.character < minCol)
			|| (position.line == maxLine && position.character > maxCol));
	}

	/// Returns: true if text range `a` and `b` intersect with at least one character.
	/// This function is commutative (a·b == b·a)
	bool intersects(const TextRange b)
	{
		return start < b.end && end > b.start;
	}

	///
	unittest
	{
		bool test(TextRange a, TextRange b)
		{
			bool res = a.intersects(b);
			// test commutativity
			assert(res == b.intersects(a));
			return res;
		}

		assert(test(TextRange(10, 4, 20, 3), TextRange(20, 2, 30, 1)));
		assert(!test(TextRange(10, 4, 20, 3), TextRange(20, 3, 30, 1)));
		assert(test(TextRange(10, 4, 20, 3), TextRange(12, 3, 14, 1)));
		assert(!test(TextRange(10, 4, 20, 3), TextRange(9, 3, 10, 4)));
		assert(test(TextRange(10, 4, 20, 3), TextRange(9, 3, 10, 5)));
		assert(test(TextRange(10, 4, 20, 3), TextRange(10, 4, 20, 3)));
		assert(test(TextRange(0, 0, 0, 1), TextRange(0, 0, uint.max, uint.max)));
		assert(!test(TextRange(0, 0, 0, 1), TextRange(uint.max, uint.max, uint.max, uint.max)));
	}
}

unittest
{
	foreach (v; [
		TextRange.init,
		TextRange(10, 4, 20, 3),
		TextRange(20, 2, 30, 1),
		TextRange(0, 0, 0, 1),
		TextRange(0, 0, uint.max, uint.max),
		TextRange(uint.max, uint.max, uint.max, uint.max)
	])
		assert(deserializeJson!TextRange(serializeJson(v)) == v);
}

@serdeFallbackStruct
struct Location
{
	DocumentUri uri;
	TextRange range;
}

@serdeFallbackStruct
struct LocationLink
{
	@serdeOptional Optional!TextRange originSelectionRange;
	DocumentUri targetUri;
	TextRange targetRange;
	TextRange targetSelectionRange;
}

@serdeFallbackStruct
struct Diagnostic
{
	TextRange range;
	@serdeOptional Optional!DiagnosticSeverity severity;
	@serdeOptional OptionalJsonValue code;
	@serdeOptional Optional!CodeDescription codeDescription;
	@serdeOptional Optional!string source;
	string message;
	@serdeOptional Optional!(DiagnosticRelatedInformation[]) relatedInformation;
	@serdeOptional Optional!(DiagnosticTag[]) tags;
	@serdeOptional OptionalJsonValue data;
}

@serdeFallbackStruct
struct CodeDescription
{
	string href;
}

@serdeFallbackStruct
struct DiagnosticRelatedInformation
{
	Location location;
	string message;
}

@serdeEnumProxy!int
enum DiagnosticSeverity
{
	error = 1,
	warning,
	information,
	hint
}

@serdeEnumProxy!int
enum DiagnosticTag
{
	unnecessary = 1,
	deprecated_
}

@serdeFallbackStruct
struct Command
{
	string title;
	string command;
	JsonValue[] arguments;
}

alias ChangeAnnotationIdentifier = string;

@serdeFallbackStruct
struct TextEdit
{
	TextRange range;
	string newText;
	@serdeOptional Optional!ChangeAnnotationIdentifier annotationId;

	this(TextRange range, string newText, ChangeAnnotationIdentifier annotationId = null)
	{
		this.range = range;
		this.newText = newText;
		if (annotationId.length)
			this.annotationId = annotationId;
	}

	this(Position[2] range, string newText, ChangeAnnotationIdentifier annotationId = null)
	{
		this.range = TextRange(range);
		this.newText = newText;
		if (annotationId.length)
			this.annotationId = annotationId;
	}
}

unittest
{
	foreach (v; [
		TextEdit([Position(0, 0), Position(4, 4)], "hello\nworld!")
	])
		assert(deserializeJson!TextEdit(serializeJson(v)) == v);
}

@serdeFallbackStruct
struct ChangeAnnotation
{
	string label;
	@serdeOptional Optional!bool needsConfirmation;
	@serdeOptional Optional!string description;
}

@serdeFallbackStruct
struct CreateFileOptions
{
	@serdeOptional Optional!bool overwrite;
	@serdeOptional Optional!bool ignoreIfExists;
}

@serdeFallbackStruct
struct CreateFile
{
	string uri;
	@serdeOptional Optional!CreateFileOptions options;
	@serdeOptional Optional!ChangeAnnotationIdentifier annotationId;
	string kind = "create";
}

@serdeFallbackStruct
struct RenameFileOptions
{
	@serdeOptional Optional!bool overwrite;
	@serdeOptional Optional!bool ignoreIfExists;
}

@serdeFallbackStruct
struct RenameFile
{
	string oldUri;
	string newUri;
	@serdeOptional Optional!RenameFileOptions options;
	@serdeOptional Optional!ChangeAnnotationIdentifier annotationId;
	string kind = "rename";
}

@serdeFallbackStruct
struct DeleteFileOptions
{
	@serdeOptional Optional!bool recursive;
	@serdeOptional Optional!bool ignoreIfNotExists;
}

@serdeFallbackStruct
struct DeleteFile
{
	string uri;
	@serdeOptional Optional!DeleteFileOptions options;
	@serdeOptional Optional!ChangeAnnotationIdentifier annotationId;
	string kind = "delete";
}

@serdeFallbackStruct
struct TextDocumentEdit
{
	VersionedTextDocumentIdentifier textDocument;
	TextEdit[] edits;
}

alias TextEditCollection = TextEdit[];

alias DocumentChange = StructVariant!(TextDocumentEdit, CreateFile, RenameFile, DeleteFile);

@serdeFallbackStruct
struct WorkspaceEdit
{
	TextEditCollection[DocumentUri] changes;

	@serdeOptional Optional!(DocumentChange[]) documentChanges;
	@serdeOptional Optional!(ChangeAnnotation[ChangeAnnotationIdentifier]) changeAnnotations;
}

@serdeFallbackStruct
struct TextDocumentIdentifier
{
	DocumentUri uri;
}

@serdeFallbackStruct
struct VersionedTextDocumentIdentifier
{
	DocumentUri uri;
	@serdeKeys("version") long version_;
}

@serdeFallbackStruct
struct TextDocumentItem
{
	DocumentUri uri;
	@serdeOptional // not actually optional according to LSP spec, logically fine to be omitted
	string languageId;
	@serdeOptional // not actually optional according to LSP spec, logically fine to be omitted
	@serdeKeys("version") long version_;
	string text;
}

@serdeFallbackStruct
struct TextDocumentPositionParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct DocumentFilter
{
	@serdeOptional Optional!string language;
	@serdeOptional Optional!string scheme;
	@serdeOptional Optional!string pattern;
}

alias DocumentSelector = DocumentFilter[];

@serdeFallbackStruct
@allowedMethods("initialize")
struct InitializeParams
{
	Variant!(typeof(null), int) processId;
	@serdeOptional Optional!string rootPath;
	DocumentUri rootUri;
	@serdeOptional OptionalJsonValue initializationOptions;
	ClientCapabilities capabilities;
	@serdeOptional Optional!string trace;
	@serdeOptional NullableOptional!(WorkspaceFolder[]) workspaceFolders;
	@serdeOptional Optional!InitializeParamsClientInfo clientInfo;
	@serdeOptional Optional!string locale;

	/// Compatibility helper to get workspace folders. Checks these members:
	/// 1) If `workspaceFolders` has any entries, it is returned as-is.
	/// 2) Otherwise, if `rootUri` is non-empty, it is returned as the only
	///    workspace, with `fallbackRootName` as name.
	/// 3) Otherwise, if `rootPath` is non-empty, it is converted to a URI and
	///    returned as the only workspace, with `fallbackRootName` as name.
	/// 4) Otherwise, empty array `[]` is returned.
	WorkspaceFolder[] getWorkspaceFolders(string fallbackRootName = "Root")
	{
		import served.lsp.uri;

		if (workspaceFolders.isSet
			&& !workspaceFolders.get.isNull
			&& workspaceFolders.get.get.length > 0
		)
			return workspaceFolders.get.get;
		else if (rootUri.length)
			return [WorkspaceFolder(rootUri, fallbackRootName)];
		else if (rootPath.orDefault.length)
			return [WorkspaceFolder(rootPath.deref.uriFromFile, fallbackRootName)];
		else
			return [];
	}
}

unittest
{
	InitializeParams p = {
		processId: 1234,
		rootUri: "file:///root/path",
		capabilities: ClientCapabilities.init
	};
	assert(p.serializeJson == `{"processId":1234,"rootUri":"file:///root/path","capabilities":{}}`, p.serializeJson);

	p = `{
		"processId":29980,
		"clientInfo": {
			"name":"Code - OSS",
			"version":"1.68.0"
		},
		"locale":"en-gb",
		"rootPath":"/home/webfreak/dev/serve-d",
		"rootUri":"file:///home/webfreak/dev/serve-d",
		"capabilities":{
			"workspace":{
				"applyEdit":true,
				"workspaceEdit":{
					"documentChanges":true,
					"resourceOperations":["create","rename","delete"],
					"failureHandling":"textOnlyTransactional",
					"normalizesLineEndings":true,
					"changeAnnotationSupport":{"groupsOnLabel":true}
				},
				"didChangeConfiguration":{
					"dynamicRegistration":true
				},
				"didChangeWatchedFiles":{
					"dynamicRegistration":true
				},
				"symbol":{
					"dynamicRegistration":true,
					"symbolKind":{
						"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]
					},
					"tagSupport":{"valueSet":[1]}
				},
				"codeLens":{
					"refreshSupport":true
				},
				"executeCommand":{
					"dynamicRegistration":true
				},
				"configuration":true,
				"workspaceFolders":true,
				"semanticTokens":{"refreshSupport":true},
				"fileOperations":{
					"dynamicRegistration":true,
					"didCreate":true,
					"didRename":true,
					"didDelete":true,
					"willCreate":true,
					"willRename":true,
					"willDelete":true
				}
			},
			"textDocument":{
				"publishDiagnostics":{
					"relatedInformation":true,
					"versionSupport":false,
					"tagSupport":{"valueSet":[1,2]},
					"codeDescriptionSupport":true,
					"dataSupport":true
				},
				"synchronization":{
					"dynamicRegistration":true,
					"willSave":true,
					"willSaveWaitUntil":true,
					"didSave":true
				},
				"completion":{
					"dynamicRegistration":true,
					"contextSupport":true,
					"completionItem":{
						"snippetSupport":true,
						"commitCharactersSupport":true,
						"documentationFormat":["markdown","plaintext"],
						"deprecatedSupport":true,
						"preselectSupport":true,
						"tagSupport":{"valueSet":[1]},
						"insertReplaceSupport":true,
						"resolveSupport":{
							"properties":["documentation","detail","additionalTextEdits"]
						},
						"insertTextModeSupport":{
							"valueSet":[1,2]
						},
						"labelDetailsSupport":true
					},
					"insertTextMode":2,
					"completionItemKind":{
						"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]
					}
				},
				"hover":{
					"dynamicRegistration":true,
					"contentFormat":["markdown","plaintext"]
				},
				"signatureHelp":{
					"dynamicRegistration":true,
					"signatureInformation":{
						"documentationFormat":["markdown","plaintext"],
						"parameterInformation":{"labelOffsetSupport":true},
						"activeParameterSupport":true
					},
					"contextSupport":true
				},
				"definition":{
					"dynamicRegistration":true,
					"linkSupport":true
				},
				"references":{
					"dynamicRegistration":true
				},
				"documentHighlight":{
					"dynamicRegistration":true
				},
				"documentSymbol":{
					"dynamicRegistration":true,
					"symbolKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]},
					"hierarchicalDocumentSymbolSupport":true,
					"tagSupport":{"valueSet":[1]},
					"labelSupport":true
				},
				"codeAction":{
					"dynamicRegistration":true,
					"isPreferredSupport":true,
					"disabledSupport":true,
					"dataSupport":true,
					"resolveSupport":{"properties":["edit"]},
					"codeActionLiteralSupport":{
						"codeActionKind":{
							"valueSet":["","quickfix","refactor","refactor.extract","refactor.inline","refactor.rewrite","source","source.organizeImports"]
						}
					},
					"honorsChangeAnnotations":false
				},
				"codeLens":{
					"dynamicRegistration":true
				},
				"formatting":{"dynamicRegistration":true},
				"rangeFormatting":{"dynamicRegistration":true},
				"onTypeFormatting":{"dynamicRegistration":true},
				"rename":{
					"dynamicRegistration":true,
					"prepareSupport":true,
					"prepareSupportDefaultBehavior":1,
					"honorsChangeAnnotations":true
				},
				"documentLink":{
					"dynamicRegistration":true,
					"tooltipSupport":true
				},
				"typeDefinition":{
					"dynamicRegistration":true,
					"linkSupport":true
				},
				"implementation":{
					"dynamicRegistration":true,
					"linkSupport":true
				},
				"colorProvider":{"dynamicRegistration":true},
				"foldingRange":{"dynamicRegistration":true,"rangeLimit":5000,"lineFoldingOnly":true},
				"declaration":{"dynamicRegistration":true,"linkSupport":true},
				"selectionRange":{"dynamicRegistration":true},
				"callHierarchy":{"dynamicRegistration":true},
				"semanticTokens":{
					"dynamicRegistration":true,
					"tokenTypes":["namespace","type","class","enum","interface","struct","typeParameter","parameter","variable","property","enumMember","event","function","method","macro","keyword","modifier","comment","string","number","regexp","operator"],
					"tokenModifiers":["declaration","definition","readonly","static","deprecated","abstract","async","modification","documentation","defaultLibrary"],
					"formats":["relative"],
					"requests":{"range":true,"full":{"delta":true}},
					"multilineTokenSupport":false,
					"overlappingTokenSupport":false
				},
				"linkedEditingRange":{"dynamicRegistration":true}
			},
			"window":{
				"showMessage":{
					"messageActionItem":{"additionalPropertiesSupport":true}
				},
				"showDocument":{"support":true},
				"workDoneProgress":true
			},
			"general":{
				"staleRequestSupport":{
					"cancel":true,
					"retryOnContentModified":["textDocument/semanticTokens/full","textDocument/semanticTokens/range","textDocument/semanticTokens/full/delta"]
				},
				"regularExpressions":{"engine":"ECMAScript","version":"ES2020"},
				"markdown":{"parser":"marked","version":"1.1.0"}
			}
		},
		"trace":"off",
		"workspaceFolders":[
			{
				"uri":"file:///home/webfreak/dev/serve-d",
				"name":"serve-d"
			}
		]
	}`.deserializeJson!InitializeParams;

	assert(p.processId == 29980);
	assert(p.clientInfo == InitializeParamsClientInfo("Code - OSS", "1.68.0".opt));
	assert(p.locale == "en-gb");
	assert(p.rootPath == "/home/webfreak/dev/serve-d");
	assert(p.rootUri == "file:///home/webfreak/dev/serve-d");
	assert(p.trace == "off");
	auto folders = p.workspaceFolders.get.get; // double get cuz this one is special because it can be omitted as well as null
	assert(folders.length == 1);
	assert(folders[0].uri == "file:///home/webfreak/dev/serve-d");
	assert(folders[0].name == "serve-d");
}

@serdeFallbackStruct
struct InitializeParamsClientInfo
{
	string name;
	@serdeKeys("version") @serdeOptional Optional!string version_;
}

@serdeFallbackStruct
struct DynamicRegistration
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeEnumProxy!string
enum ResourceOperationKind : string
{
	create = "create",
	rename = "rename",
	delete_ = "delete"
}

@serdeEnumProxy!string
enum FailureHandlingKind : string
{
	abort = "abort",
	transactional = "transactional",
	textOnlyTransactional = "textOnlyTransactional",
	undo = "undo"
}

@serdeFallbackStruct
struct WorkspaceEditClientCapabilities
{
	@serdeOptional Optional!bool documentChanges;
	@serdeOptional Optional!(ResourceOperationKind[]) resourceOperations;
	@serdeOptional Optional!FailureHandlingKind failureHandling;
	@serdeOptional Optional!bool normalizesLineEndings;
	@serdeOptional Optional!ChangeAnnotationWorkspaceEditClientCapabilities changeAnnotationSupport;
}

unittest
{
	WorkspaceEditClientCapabilities cap = {
		documentChanges: true,
		resourceOperations: [ResourceOperationKind.delete_],
		failureHandling: FailureHandlingKind.textOnlyTransactional
	};

	assert(cap.serializeJson == `{"documentChanges":true,"resourceOperations":["delete"],"failureHandling":"textOnlyTransactional"}`);
}

@serdeFallbackStruct
struct ChangeAnnotationWorkspaceEditClientCapabilities
{
	@serdeOptional Optional!bool groupsOnLabel;
}

@serdeFallbackStruct
struct WorkspaceClientCapabilities
{
	@serdeOptional Optional!bool applyEdit;
	@serdeOptional Optional!WorkspaceEditClientCapabilities workspaceEdit;
	@serdeOptional Optional!DynamicRegistration didChangeConfiguration;
	@serdeOptional Optional!DynamicRegistration didChangeWatchedFiles;
	@serdeOptional Optional!DynamicRegistration symbol;
	@serdeOptional Optional!DynamicRegistration executeCommand;
	@serdeOptional Optional!bool workspaceFolders;
	@serdeOptional Optional!bool configuration;
	@serdeOptional Optional!SemanticTokensWorkspaceClientCapabilities semanticTokens;
	@serdeOptional Optional!CodeLensWorkspaceClientCapabilities codeLens;
	@serdeOptional Optional!FileOperationsCapabilities fileOperations;
}

@serdeFallbackStruct
struct MonikerClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct MonikerOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct MonikerRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/moniker")
struct MonikerParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeEnumProxy!string
enum UniquenessLevel : string
{
	document = "document",
	project = "project",
	group = "group",
	scheme = "scheme",
	global = "global"
}

@serdeEnumProxy!string
enum MonikerKind : string
{
	import_ = "import",
	export_ = "export",
	local = "local"
}

@serdeFallbackStruct
struct Moniker
{
	string scheme;
	string identifier;
	UniquenessLevel unique;
	@serdeOptional Optional!MonikerKind kind;
}

@serdeFallbackStruct
struct FileOperationsCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!bool didCreate;
	@serdeOptional Optional!bool willCreate;
	@serdeOptional Optional!bool didRename;
	@serdeOptional Optional!bool willRename;
	@serdeOptional Optional!bool didDelete;
	@serdeOptional Optional!bool willDelete;
}

@serdeFallbackStruct
struct TextDocumentClientCapabilities
{
	@serdeOptional Optional!TextDocumentSyncClientCapabilities synchronization;
	@serdeOptional Optional!CompletionClientCapabilities completion;
	@serdeOptional Optional!HoverClientCapabilities hover;
	@serdeOptional Optional!SignatureHelpClientCapabilities signatureHelp;
	@serdeOptional Optional!DeclarationClientCapabilities declaration;
	@serdeOptional Optional!DefinitionClientCapabilities definition;
	@serdeOptional Optional!TypeDefinitionClientCapabilities typeDefinition;
	@serdeOptional Optional!ImplementationClientCapabilities implementation;
	@serdeOptional Optional!ReferenceClientCapabilities references;
	@serdeOptional Optional!DocumentHighlightClientCapabilities documentHighlight;
	@serdeOptional Optional!DocumentSymbolClientCapabilities documentSymbol;
	@serdeOptional Optional!CodeActionClientCapabilities codeAction;
	@serdeOptional Optional!CodeLensClientCapabilities codeLens;
	@serdeOptional Optional!DocumentLinkClientCapabilities documentLink;
	@serdeOptional Optional!DocumentColorClientCapabilities colorProvider;
	@serdeOptional Optional!DocumentFormattingClientCapabilities formatting;
	@serdeOptional Optional!DocumentRangeFormattingClientCapabilities rangeFormatting;
	@serdeOptional Optional!DocumentOnTypeFormattingClientCapabilities onTypeFormatting;
	@serdeOptional Optional!RenameClientCapabilities rename;
	@serdeOptional Optional!PublishDiagnosticsClientCapabilities publishDiagnostics;
	@serdeOptional Optional!FoldingRangeClientCapabilities foldingRange;
	@serdeOptional Optional!SelectionRangeClientCapabilities selectionRange;
	@serdeOptional Optional!LinkedEditingRangeClientCapabilities linkedEditingRange;
	@serdeOptional Optional!CallHierarchyClientCapabilities callHierarchy;
	@serdeOptional Optional!SemanticTokensClientCapabilities semanticTokens;
	@serdeOptional Optional!MonikerClientCapabilities moniker;
}

@serdeFallbackStruct
struct ClientCapabilities
{
	@serdeOptional Optional!WorkspaceClientCapabilities workspace;
	@serdeOptional Optional!TextDocumentClientCapabilities textDocument;
	@serdeOptional Optional!WindowClientCapabilities window;
	@serdeOptional Optional!GeneralClientCapabilities general;
	@serdeOptional OptionalJsonValue experimental;
}

@serdeFallbackStruct
struct WindowClientCapabilities
{
	@serdeOptional Optional!bool workDoneProgress;
	@serdeOptional Optional!ShowMessageRequestClientCapabilities showMessage;
	@serdeOptional Optional!ShowDocumentClientCapabilities showDocument;
}

@serdeFallbackStruct
struct GeneralClientCapabilities
{
	@serdeOptional Optional!RegularExpressionsClientCapabilities regularExpressions;
	@serdeOptional Optional!MarkdownClientCapabilities markdown;
}

@serdeFallbackStruct
struct RegularExpressionsClientCapabilities
{
	string engine;
	@serdeKeys("version") @serdeOptional Optional!string version_;
}

unittest
{
	string json = q{{
		"workspace": {
			"configuration": true
		}
	}};
	auto caps = json.deserializeJson!ClientCapabilities;
	assert(caps.workspace.deref.configuration.deref);
}

@serdeFallbackStruct
struct InitializeResult
{
	ServerCapabilities capabilities;
	@serdeOptional Optional!ServerInfo serverInfo;
}

// TODO: deserialization broken here because of TextDocumentSync
// (see linters at the very bottom of this file)
version (none)
unittest
{
	auto res = `{
		"capabilities":{
			"textDocumentSync":2,
			"completionProvider":{
				"resolveProvider":false,
				"triggerCharacters":[".","=","/","*","+","-"],
				"completionItem":{"labelDetailsSupport":true}
			},
			"hoverProvider":true,
			"signatureHelpProvider":{
				"triggerCharacters":["(","[",","]
			},
			"definitionProvider":true,
			"documentHighlightProvider":true,
			"documentSymbolProvider":true,
			"codeActionProvider":true,
			"codeLensProvider":{"resolveProvider":true},
			"colorProvider":{},
			"documentFormattingProvider":true,
			"documentRangeFormattingProvider":true,
			"workspaceSymbolProvider":true,
			"workspace":{
				"workspaceFolders":{
					"supported":true,
					"changeNotifications":true
				}
			}
		}
	}`
		.deserializeJson!InitializeResult;
	assert(res.capabilities.textDocumentSync == TextDocumentSyncKind.incremental);
}

@serdeFallbackStruct
struct ServerInfo
{
	string name;
	@serdeKeys("version") @serdeOptional Optional!string version_;
}

@serdeFallbackStruct
struct InitializeError
{
	bool retry;
}

@serdeFallbackStruct
struct CompletionClientCapabilities
{
	@serdeFallbackStruct
	@serdeIgnoreUnexpectedKeys
	static struct CompletionItemCapabilities
	{
		@serdeFallbackStruct
		@serdeIgnoreUnexpectedKeys
		static struct ResolveSupport
		{
			string[] properties;
		}

		@serdeOptional Optional!bool snippetSupport;
		@serdeOptional Optional!bool commitCharactersSupport;
		@serdeOptional Optional!(MarkupKind[]) documentationFormat;
		@serdeOptional Optional!bool deprecatedSupport;
		@serdeOptional Optional!bool preselectSupport;
		@serdeOptional Optional!(RequiredValueSet!CompletionItemTag) tagSupport;
		@serdeOptional Optional!bool insertReplaceSupport;
		@serdeOptional Optional!ResolveSupport resolveSupport;
		@serdeOptional Optional!(RequiredValueSet!InsertTextMode) insertTextModeSupport;
		@serdeOptional Optional!bool labelDetailsSupport;
	}

	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!CompletionItemCapabilities completionItem;
	@serdeOptional Optional!(OptionalValueSet!CompletionItemKind) completionItemKind;
	@serdeOptional Optional!bool contextSupport;
}

@serdeFallbackStruct
struct CompletionOptions
{
	@serdeFallbackStruct
	@serdeIgnoreUnexpectedKeys
	struct CompletionItem
	{
		@serdeOptional Optional!bool labelDetailsSupport;
	}

	@serdeOptional Optional!bool resolveProvider;
	@serdeOptional Optional!(string[]) triggerCharacters;
	@serdeOptional Optional!(string[]) allCommitCharacters;
	@serdeOptional Optional!CompletionItem completionItem;
}

@serdeFallbackStruct
struct SaveOptions
{
	@serdeOptional Optional!bool includeText;
}

@serdeFallbackStruct
struct TextDocumentSyncClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!bool willSave;
	@serdeOptional Optional!bool willSaveWaitUntil;
	@serdeOptional Optional!bool didSave;
}

@serdeEnumProxy!int
enum TextDocumentSyncKind
{
	none,
	full,
	incremental
}

@serdeFallbackStruct
struct TextDocumentSyncOptions
{
	@serdeOptional Optional!bool openClose;
	@serdeOptional Optional!TextDocumentSyncKind change;
	@serdeOptional Optional!bool willSave;
	@serdeOptional Optional!bool willSaveWaitUntil;
	@serdeOptional Variant!(void, bool, SaveOptions) save;
}

@serdeFallbackStruct
struct ServerCapabilities
{
	@serdeOptional Variant!(void, TextDocumentSyncKind, TextDocumentSyncOptions) textDocumentSync;
	@serdeOptional Variant!(void, CompletionOptions) completionProvider;
	@serdeOptional Variant!(void, bool, HoverOptions) hoverProvider;
	@serdeOptional Variant!(void, SignatureHelpOptions) signatureHelpProvider;
	@serdeOptional Variant!(void, bool, StructVariant!(DeclarationOptions, DeclarationRegistrationOptions)) declarationProvider;
	@serdeOptional Variant!(void, bool, DefinitionOptions) definitionProvider;
	@serdeOptional Variant!(void, bool, StructVariant!(TypeDefinitionOptions, TypeDefinitionRegistrationOptions)) typeDefinitionProvider;
	@serdeOptional Variant!(void, bool, StructVariant!(ImplementationOptions, ImplementationRegistrationOptions)) implementationProvider;
	@serdeOptional Variant!(void, bool, ReferenceOptions) referencesProvider;
	@serdeOptional Variant!(void, bool, DocumentHighlightOptions) documentHighlightProvider;
	@serdeOptional Variant!(void, bool, DocumentSymbolOptions) documentSymbolProvider;
	@serdeOptional Variant!(void, bool, InlayHintOptions) inlayHintProvider;
	@serdeOptional Variant!(void, bool, CodeActionOptions) codeActionProvider;
	@serdeOptional Variant!(void, CodeLensOptions) codeLensProvider;
	@serdeOptional Variant!(void, DocumentLinkOptions) documentLinkProvider;
	@serdeOptional Variant!(void, bool, StructVariant!(DocumentColorOptions, DocumentColorRegistrationOptions)) colorProvider;
	@serdeOptional Variant!(void, bool, DocumentFormattingOptions) documentFormattingProvider;
	@serdeOptional Variant!(void, bool, DocumentRangeFormattingOptions) documentRangeFormattingProvider;
	@serdeOptional Variant!(void, DocumentOnTypeFormattingOptions) documentOnTypeFormattingProvider;
	@serdeOptional Variant!(void, bool, RenameOptions) renameProvider;
	@serdeOptional Variant!(void, bool, StructVariant!(FoldingRangeOptions, FoldingRangeRegistrationOptions)) foldingRangeProvider;
	@serdeOptional Variant!(void, ExecuteCommandOptions) executeCommandProvider;
	@serdeOptional Variant!(void, bool, StructVariant!(SelectionRangeOptions, SelectionRangeRegistrationOptions)) selectionRangeProvider;
	@serdeOptional Variant!(void, bool, StructVariant!(LinkedEditingRangeOptions, LinkedEditingRangeRegistrationOptions)) linkedEditingRangeProvider;
	@serdeOptional Variant!(void, bool, StructVariant!(CallHierarchyOptions, CallHierarchyRegistrationOptions)) callHierarchyProvider;
	@serdeOptional Variant!(void, StructVariant!(SemanticTokensOptions, SemanticTokensRegistrationOptions)) semanticTokensProvider;
	@serdeOptional Variant!(void, bool, StructVariant!(MonikerOptions, MonikerRegistrationOptions)) monikerProvider;
	@serdeOptional Variant!(void, bool, WorkspaceSymbolOptions) workspaceSymbolProvider;

	@serdeOptional Optional!ServerWorkspaceCapabilities workspace;
	@serdeOptional OptionalJsonValue experimental;
}

unittest
{
	CodeActionOptions cao = {
		codeActionKinds: [CodeActionKind.refactor, CodeActionKind.sourceOrganizeImports, cast(CodeActionKind)"CustomKind"]
	};
	FoldingRangeOptions foldingRangeProvider;
	ServerCapabilities cap = {
		textDocumentSync: TextDocumentSyncKind.incremental,
		codeActionProvider: cao,
		foldingRangeProvider: foldingRangeProvider
	};
	assert(cap.serializeJson == `{"textDocumentSync":2,"codeActionProvider":{"codeActionKinds":["refactor","source.organizeImports","CustomKind"]},"foldingRangeProvider":{}}`, cap.serializeJson);
}

@serdeFallbackStruct
@allowedMethods("initialized")
struct InitializedParams
{
}

@serdeFallbackStruct
struct ServerWorkspaceCapabilities
{
	@serdeOptional Optional!WorkspaceFoldersServerCapabilities workspaceFolders;
	@serdeOptional Optional!WorkspaceFileOperationsCapabilities fileOperations;
}

@serdeFallbackStruct
struct WorkspaceFoldersServerCapabilities
{
	@serdeOptional Optional!bool supported;
	@serdeOptional Variant!(void, bool, string) changeNotifications;
}

@serdeFallbackStruct
struct WorkspaceFileOperationsCapabilities
{
	@serdeOptional Optional!FileOperationRegistrationOptions didCreate;
	@serdeOptional Optional!FileOperationRegistrationOptions willCreate;
	@serdeOptional Optional!FileOperationRegistrationOptions didRename;
	@serdeOptional Optional!FileOperationRegistrationOptions willRename;
	@serdeOptional Optional!FileOperationRegistrationOptions didDelete;
	@serdeOptional Optional!FileOperationRegistrationOptions willDelete;
}

@serdeFallbackStruct
struct FileOperationRegistrationOptions
{
	FileOperationFilter[] filters;
}

@serdeEnumProxy!string
enum FileOperationPatternKind : string
{
	file = "file",
	folder = "folder"
}

@serdeFallbackStruct
struct FileOperationPatternOptions
{
	@serdeOptional Optional!bool ignoreCase;
}

@serdeFallbackStruct
struct FileOperationPattern
{
	string glob;
	@serdeOptional Optional!FileOperationPatternKind matches;
	@serdeOptional Optional!FileOperationPatternOptions options;
}

@serdeFallbackStruct
struct FileOperationFilter
{
	FileOperationPattern pattern;
	@serdeOptional Optional!string scheme;
}

@serdeFallbackStruct
@allowedMethods("workspace/willCreateFiles", "workspace/didCreateFiles")
struct CreateFilesParams
{
	FileCreate[] files;
}

@serdeFallbackStruct
struct FileCreate
{
	string uri;
}

@serdeFallbackStruct
@allowedMethods("workspace/willRenameFiles", "workspace/didRenameFiles")
struct RenameFilesParams
{
	FileRename[] files;
}

@serdeFallbackStruct
struct FileRename
{
	string oldUri;
	string newUri;
}

@serdeFallbackStruct
@allowedMethods("workspace/willDeleteFiles", "workspace/didDeleteFiles")
struct DeleteFilesParams
{
	FileDelete[] files;
}

@serdeFallbackStruct
struct FileDelete
{
	string uri;
}

@serdeFallbackStruct
struct Registration
{
	string id;
	string method;
	@serdeOptional OptionalJsonValue registerOptions;
}

@serdeFallbackStruct
@allowedMethods("client/registerCapability")
struct RegistrationParams
{
	Registration[] registrations;
}

@serdeFallbackStruct
struct Unregistration
{
	string id;
	string method;
}

@serdeFallbackStruct
@allowedMethods("client/unregisterCapability")
struct UnregistrationParams
{
	Unregistration[] unregistrations;
}

mixin template TextDocumentRegistrationOptions()
{
	@serdeOptional Optional!DocumentSelector documentSelector;
}

mixin template WorkDoneProgressOptions()
{
	@serdeOptional Optional!bool workDoneProgress;
}

mixin template StaticRegistrationOptions()
{
	@serdeOptional Optional!string id;
}

@serdeFallbackStruct
struct DidChangeConfigurationClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

/// You might want to use `RootJsonToken` instead of this type if you want to
/// deserialize your custom config types.
@serdeFallbackStruct
@allowedMethods("workspace/didChangeConfiguration")
struct DidChangeConfigurationParams
{
	JsonValue settings;
}

@serdeFallbackStruct
@allowedMethods("workspace/configuration")
struct ConfigurationParams
{
	ConfigurationItem[] items;
}

@serdeFallbackStruct
struct ConfigurationItem
{
	@serdeOptional Optional!string scopeUri;
	@serdeOptional Optional!string section;
}

@serdeFallbackStruct
@allowedMethods("textDocument/didOpen")
struct DidOpenTextDocumentParams
{
	TextDocumentItem textDocument;
}

@serdeFallbackStruct
@allowedMethods("textDocument/didChange")
struct DidChangeTextDocumentParams
{
	VersionedTextDocumentIdentifier textDocument;
	TextDocumentContentChangeEvent[] contentChanges;
}

@serdeFallbackStruct
struct TextDocumentContentChangeEvent
{
	@serdeOptional Optional!TextRange range;
	string text;
}

@serdeFallbackStruct
struct TextDocumentChangeRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;

	TextDocumentSyncKind syncKind;
}

@serdeFallbackStruct
@allowedMethods("textDocument/willSave", "textDocument/willSaveWaitUntil")
struct WillSaveTextDocumentParams
{
	TextDocumentIdentifier textDocument;
	TextDocumentSaveReason reason;
}

@serdeEnumProxy!int
enum TextDocumentSaveReason
{
	manual = 1,
	afterDelay,
	focusOut
}

@serdeFallbackStruct
struct TextDocumentSaveRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;

	@serdeOptional Optional!bool includeText;
}

@serdeFallbackStruct
@allowedMethods("textDocument/didSave")
struct DidSaveTextDocumentParams
{
	TextDocumentIdentifier textDocument;
	@serdeOptional Optional!string text;
}

@serdeFallbackStruct
@allowedMethods("textDocument/didClose")
struct DidCloseTextDocumentParams
{
	TextDocumentIdentifier textDocument;
}

@serdeFallbackStruct
struct FileSystemWatcher
{
	string globPattern;
	@serdeOptional Optional!WatchKind kind;
}

@serdeEnumProxy!int
enum WatchKind
{
	create = 1,
	change = 2,
	delete_ = 4
}

unittest
{
	FileSystemWatcher w = {
		globPattern: "**/foo.d",
		kind: WatchKind.change | WatchKind.delete_
	};
	assert(w.serializeJson == `{"globPattern":"**/foo.d","kind":6}`);
}

@serdeFallbackStruct
struct DidChangeWatchedFilesClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct DidChangeWatchedFilesRegistrationOptions
{
	FileSystemWatcher[] watchers;
}

@serdeFallbackStruct
@allowedMethods("workspace/didChangeWatchedFiles")
struct DidChangeWatchedFilesParams
{
	FileEvent[] changes;
}

@serdeFallbackStruct
struct FileEvent
{
	DocumentUri uri;
	FileChangeType type;
}

@serdeEnumProxy!int
enum FileChangeType
{
	created = 1,
	changed,
	deleted
}

@serdeFallbackStruct
struct WorkspaceSymbolClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!(OptionalValueSet!SymbolKind) symbolKind;
	@serdeOptional Optional!(RequiredValueSet!SymbolTag) tagSupport;
}

@serdeFallbackStruct
struct WorkspaceSymbolOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct WorkspaceSymbolRegistrationOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
@allowedMethods("workspace/symbol")
struct WorkspaceSymbolParams
{
	string query;
}

@serdeFallbackStruct
struct PublishDiagnosticsClientCapabilities
{
	@serdeOptional Optional!bool relatedInformation;
	@serdeOptional Optional!(RequiredValueSet!DiagnosticTag) tagSupport;
	@serdeOptional Optional!bool versionSupport;
	@serdeOptional Optional!bool codeDescriptionSupport;
	@serdeOptional Optional!bool dataSupport;
}

@serdeFallbackStruct
@allowedMethods("textDocument/publishDiagnostics")
struct PublishDiagnosticsParams
{
	DocumentUri uri;
	Diagnostic[] diagnostics;
	@serdeKeys("version") @serdeOptional Optional!int version_;
}

@serdeFallbackStruct
struct CompletionRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;

	@serdeOptional Optional!(string[]) triggerCharacters;
	bool resolveProvider;
}

@serdeFallbackStruct
@allowedMethods("textDocument/completion")
struct CompletionParams
{
	TextDocumentIdentifier textDocument;
	Position position;
	@serdeOptional Optional!CompletionContext context;
}

@serdeEnumProxy!int
enum CompletionTriggerKind
{
	invoked = 1,
	triggerCharacter = 2,
	triggerForIncompleteCompletions = 3
}

@serdeFallbackStruct
struct CompletionContext
{
	CompletionTriggerKind triggerKind;
	@serdeOptional Optional!string triggerCharacter;
}

@serdeFallbackStruct
struct CompletionList
{
	bool isIncomplete;
	CompletionItem[] items;
}

@serdeEnumProxy!int
enum InsertTextFormat
{
	plainText = 1,
	snippet
}

@serdeEnumProxy!int
enum CompletionItemTag
{
	deprecated_ = 1
}

@serdeFallbackStruct
struct InsertReplaceEdit
{
	string newText;
	TextRange insert;
	TextRange replace;
}

unittest
{
	string s = `{"newText":"new text","insert":{"start":{"line":1,"character":2},"end":{"line":3,"character":4}},"replace":{"start":{"line":5,"character":6},"end":{"line":7,"character":8}}}`;
	auto v = InsertReplaceEdit(
		"new text",
		TextRange(1, 2, 3, 4),
		TextRange(5, 6, 7, 8)
	);
	assert(s.deserializeJson!InsertReplaceEdit == v);

	Variant!(void, InsertReplaceEdit) var = v;
	assert(s.deserializeJson!(typeof(var)) == var);

	Variant!(void, StructVariant!(TextEdit, InsertReplaceEdit)) var2 = v;
	assert(s.deserializeJson!(typeof(var2)) == var2);

	struct Struct
	{
		Variant!(void, StructVariant!(TextEdit, InsertReplaceEdit)) edit;
	}

	Struct str;
	str.edit = StructVariant!(TextEdit, InsertReplaceEdit)(v);
	auto strS = `{"edit":` ~ s ~ `}`;
	assert(str.serializeJson == strS);
	assert(strS.deserializeJson!Struct == str, strS.deserializeJson!Struct.to!string ~ " !=\n" ~ str.to!string);
}

@serdeEnumProxy!int
enum InsertTextMode
{
	asIs = 1,
	adjustIndentation = 2
}

@serdeFallbackStruct
struct CompletionItemLabelDetails
{
	/**
	 * An optional string which is rendered less prominently directly after
	 * {@link CompletionItemLabel.label label}, without any spacing. Should be
	 * used for function signatures or type annotations.
	 */
	@serdeOptional Optional!string detail;

	/**
	 * An optional string which is rendered less prominently after
	 * {@link CompletionItemLabel.detail}. Should be used for fully qualified
	 * names or file path.
	 */
	@serdeOptional Optional!string description;
}

@serdeFallbackStruct
struct CompletionItem
{
	string label;
	@serdeOptional Optional!CompletionItemLabelDetails labelDetails;
	@serdeOptional Optional!CompletionItemKind kind;
	@serdeOptional Optional!(CompletionItemTag[]) tags;
	@serdeOptional Optional!string detail;
	@serdeOptional Variant!(void, string, MarkupContent) documentation;
	@serdeOptional Optional!bool preselect;
	@serdeOptional Optional!string sortText;
	@serdeOptional Optional!string filterText;
	@serdeOptional Optional!string insertText;
	@serdeOptional Optional!InsertTextFormat insertTextFormat;
	@serdeOptional Optional!InsertTextMode insertTextMode;
	@serdeOptional Variant!(void, StructVariant!(TextEdit, InsertReplaceEdit)) textEdit;
	@serdeOptional Optional!(TextEdit[]) additionalTextEdits;
	@serdeOptional Optional!(string[]) commitCharacters;
	@serdeOptional Optional!Command command;
	@serdeOptional OptionalJsonValue data;

	string effectiveInsertText() const
	{
		return insertText.isNone ? label : insertText.deref;
	}
}

unittest
{
	CompletionItem[] values = [CompletionItem("hello")];
	CompletionItem b = {
		label: "b",
		detail: "detail".opt
	}; values ~= b;
	CompletionItem c = {
		label: "c",
		documentation: MarkupContent("cool beans")
	}; values ~= c;
	CompletionItem d = {
		label: "d",
		textEdit: TextEdit(TextRange(1, 2, 3, 4), "new text")
	}; values ~= d;
	CompletionItem e = {
		label: "e",
		textEdit: InsertReplaceEdit("new text", TextRange(1, 2, 3, 4), TextRange(5, 6, 7, 8))
	}; values ~= e;

	string[] expected = [
		`{"label":"hello"}`,
		`{"label":"b","detail":"detail"}`,
		`{"label":"c","documentation":{"kind":"plaintext","value":"cool beans"}}`,
		`{"label":"d","textEdit":{"range":{"start":{"line":1,"character":2},"end":{"line":3,"character":4}},"newText":"new text"}}`,
		`{"label":"e","textEdit":{"newText":"new text","insert":{"start":{"line":1,"character":2},"end":{"line":3,"character":4}},"replace":{"start":{"line":5,"character":6},"end":{"line":7,"character":8}}}}`,
	];

	foreach (i, v; values)
		assert(v.serializeJson == expected[i], v.serializeJson ~ " !=\n" ~ expected[i]);

	foreach (v; values)
		assert(deserializeJson!CompletionItem(v.serializeJson) == v, v.to!string ~ " !=\n" ~ v.serializeJson.deserializeJson!CompletionItem.to!string);
}

unittest
{
	auto str = `{
		"label":"toStringText",
		"detail":"string toString() in struct using std.conv:text",
		"documentation":{
			"kind":"markdown",
			"value":"doc text"
		},
		"filterText":"toStringText",
		"insertTextFormat":2,
		"insertText":"myInsertText",
		"kind":15,
		"sortText":"2_5_toStringText",
		"data":{
			"level":"type",
			"column":5,
			"format":"dfmt args",
			"uri":"file:///home/webfreak/dev/serve-d/source/served/lsp/protoext.d",
			"line":305
		}
	}`;

	CompletionItem item = str.deserializeJson!CompletionItem;
	assert(item.label == "toStringText");
	assert(item.detail.deref == "string toString() in struct using std.conv:text");
	assert(item.documentation.get!MarkupContent == MarkupContent(MarkupKind.markdown, "doc text"));
	assert(item.filterText.deref == "toStringText");
	assert(item.insertTextFormat.deref == InsertTextFormat.snippet);
	assert(item.insertText.deref == "myInsertText");
	assert(item.kind.deref == CompletionItemKind.snippet);
	assert(item.sortText.deref == "2_5_toStringText");
	auto data = item.data.deref.get!(StringMap!JsonValue);
	assert(data["level"].get!string == "type");
	assert(data["column"].get!long == 5);
	assert(data["format"].get!string == "dfmt args");
	assert(data["uri"].get!string == "file:///home/webfreak/dev/serve-d/source/served/lsp/protoext.d");
	assert(data["line"].get!long == 305);
}

@serdeEnumProxy!int
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

@serdeFallbackStruct
struct HoverClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!(MarkupKind[]) contentFormat;
}

@serdeFallbackStruct
struct HoverOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct HoverRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/hover")
struct HoverParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct Hover
{
	Variant!(StructVariant!(MarkedString, MarkupContent), MarkedString[]) contents;
	@serdeOptional Optional!TextRange range;
}

@serdeFallbackStruct
struct MarkedString
{
	import mir.ion.exception;
	import mir.ion.value;
	import mir.deser.ion : deserializeIon;
	import mir.ion.type_code : IonTypeCode;

	string value;
	string language;

	private static struct SerializeHelper
	{
		string value;
		string language;
	}

	void serialize(S)(scope ref S serializer) const
	{
		import mir.ser : serializeValue;

		if (language.length)
		{
			auto helper = SerializeHelper(value, language);
			serializeValue(serializer, helper);
		}
		else
			serializer.putValue(value);
	}

	/**
	Returns: error msg if any
	*/
	@safe pure scope
	IonException deserializeFromIon(scope const char[][] symbolTable, IonDescribedValue value)
	{
		import mir.deser.ion : deserializeIon;
		import mir.ion.type_code : IonTypeCode;

		if (value.descriptor.type == IonTypeCode.string)
		{
			this.value = deserializeIon!string(symbolTable, value);
			this.language = null;
		}
		else if (value.descriptor.type == IonTypeCode.struct_)
		{
			auto p = deserializeIon!SerializeHelper(symbolTable, value);
			this.value = p.value;
			this.language = p.language;
		}
		else
			return ionException(IonErrorCode.jsonUnexpectedValue);
		return null;
	}
}

@serdeEnumProxy!string
enum MarkupKind : string
{
	plaintext = "plaintext",
	markdown = "markdown"
}

@serdeFallbackStruct
struct MarkupContent
{
	string kind;
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

@serdeFallbackStruct
struct MarkdownClientCapabilities
{
	string parser;
	@serdeKeys("version") @serdeOptional Optional!string version_;
}

@serdeFallbackStruct
struct SignatureHelpClientCapabilities
{
	@serdeFallbackStruct
	@serdeIgnoreUnexpectedKeys
	static struct SignatureInformationCapabilities
	{
		@serdeFallbackStruct
		@serdeIgnoreUnexpectedKeys
		static struct ParameterInformationSupport
		{
			@serdeOptional Optional!bool labelOffsetSupport;
		}

		@serdeOptional Optional!(MarkupKind[]) documentationFormat;
		@serdeOptional Optional!ParameterInformationSupport parameterInformation;
		@serdeOptional Optional!bool activeParameterSupport;
	}

	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!SignatureInformationCapabilities signatureInformation;
	@serdeOptional Optional!bool contextSupport;
}

@serdeFallbackStruct
struct SignatureHelpOptions
{
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!(string[]) triggerCharacters;
	@serdeOptional Optional!(string[]) retriggerCharacters;
}

@serdeFallbackStruct
struct SignatureHelpRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!(string[]) triggerCharacters;
	@serdeOptional Optional!(string[]) retriggerCharacters;
}

@serdeFallbackStruct
@allowedMethods("textDocument/signatureHelp")
struct SignatureHelpParams
{
	TextDocumentIdentifier textDocument;
	Position position;
	@serdeOptional Optional!SignatureHelpContext context;
}

@serdeEnumProxy!int
enum SignatureHelpTriggerKind
{
	invoked = 1,
	triggerCharacter,
	contentChange
}

@serdeFallbackStruct
struct SignatureHelpContext
{
	SignatureHelpTriggerKind triggerKind;
	@serdeOptional Optional!string triggerCharacter;
	@serdeOptional Optional!bool isRetrigger;
	@serdeOptional Optional!SignatureHelp activeSignatureHelp;
}

@serdeFallbackStruct
struct SignatureHelp
{
	SignatureInformation[] signatures;
	@serdeOptional Optional!uint activeSignature;
	@serdeOptional Optional!uint activeParameter;

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

	this(SignatureInformation[] signatures, uint activeSignature, uint activeParameter)
	{
		this.signatures = signatures;
		this.activeSignature = activeSignature;
		this.activeParameter = activeParameter;
	}
}

@serdeFallbackStruct
struct SignatureInformation
{
	string label;
	@serdeOptional Variant!(void, string, MarkupContent) documentation;
	@serdeOptional Optional!(ParameterInformation[]) parameters;
	@serdeOptional Optional!uint activeParameter;
}

@serdeFallbackStruct
struct ParameterInformation
{
	Variant!(string, uint[2]) label;
	@serdeOptional Variant!(void, string, MarkupContent) documentation;
}

@serdeFallbackStruct
struct DeclarationClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!bool linkSupport;
}

@serdeFallbackStruct
struct DeclarationOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct DeclarationRegistrationOptions
{
	mixin WorkDoneProgressOptions;
	mixin TextDocumentRegistrationOptions;
	mixin StaticRegistrationOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/declaration")
struct DeclarationParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct DefinitionClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!bool linkSupport;
}

@serdeFallbackStruct
struct DefinitionOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct DefinitionRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/definition")
struct DefinitionParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct TypeDefinitionClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!bool linkSupport;
}

@serdeFallbackStruct
struct TypeDefinitionOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct TypeDefinitionRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
	mixin StaticRegistrationOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/typeDefinition")
struct TypeDefinitionParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct ImplementationClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!bool linkSupport;
}

@serdeFallbackStruct
struct ImplementationOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct ImplementationRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
	mixin StaticRegistrationOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/implementation")
struct ImplementationParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct ReferenceClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct ReferenceOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct ReferenceRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/references")
struct ReferenceParams
{
	TextDocumentIdentifier textDocument;
	Position position;
	ReferenceContext context;
}

@serdeFallbackStruct
@allowedMethods("textDocument/inlayHint")
struct InlayHintParams
{
	TextDocumentIdentifier textDocument;
	TextRange range;
}

@serdeFallbackStruct
struct InlayHint
{
    Position position;
    Variant!(string, InlayHintLabelPart[]) label;
    @serdeOptional Optional!InlayHintKind kind;
    @serdeOptional Optional!(TextEdit[]) textEdits;
    @serdeOptional Variant!(void, string, MarkupContent) tooltip;
    @serdeOptional Optional!(bool) paddingLeft;
    @serdeOptional Optional!(bool) paddingRight;
	OptionalJsonValue data;
}

@serdeEnumProxy!uint
enum InlayHintKind
{
    type = 1,
    parameter = 2,
}

@serdeFallbackStruct
struct InlayHintLabelPart
{
    string value;
    @serdeOptional Variant!(void, string, MarkupContent) tooltip;
    @serdeOptional Optional!Location location;
    @serdeOptional Optional!Command command;
}

@serdeFallbackStruct
struct ReferenceContext
{
	bool includeDeclaration;
}

@serdeFallbackStruct
struct DocumentHighlightClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct DocumentHighlightOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct DocumentHighlightRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/documentHighlight")
struct DocumentHighlightParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct DocumentHighlight
{
	TextRange range;
	@serdeOptional Optional!DocumentHighlightKind kind;
}

@serdeEnumProxy!int
enum DocumentHighlightKind
{
	text = 1,
	read,
	write
}

@serdeFallbackStruct
struct DocumentSymbolClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!(OptionalValueSet!SymbolKind) symbolKind;
	@serdeOptional Optional!bool hierarchicalDocumentSymbolSupport;
	@serdeOptional Optional!(RequiredValueSet!SymbolTag) tagSupport;
	@serdeOptional Optional!bool labelSupport;
}

@serdeFallbackStruct
struct DocumentSymbolOptions
{
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!string label;
}

@serdeFallbackStruct
struct InlayHintOptions
{
	mixin WorkDoneProgressOptions;
	@serdeOptional Optional!bool resolveProvider;
}

@serdeFallbackStruct
struct DocumentSymbolRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!string label;
}

@serdeFallbackStruct
@allowedMethods("textDocument/documentSymbol")
struct DocumentSymbolParams
{
	TextDocumentIdentifier textDocument;
}

@serdeEnumProxy!int
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

@serdeEnumProxy!int
enum SymbolTag
{
	deprecated_ = 1
}

@serdeFallbackStruct
struct DocumentSymbol
{
	string name;
	@serdeOptional Optional!string detail;
	SymbolKind kind;
	@serdeOptional Optional!(SymbolTag[]) tags;
	TextRange range;
	TextRange selectionRange;
	DocumentSymbol[] children;
}

@serdeFallbackStruct
struct SymbolInformation
{
	string name;
	SymbolKind kind;
	@serdeOptional Optional!(SymbolTag[]) tags;
	Location location;
	@serdeOptional Optional!string containerName;
}

@serdeFallbackStruct
struct CodeActionClientCapabilities
{
	@serdeFallbackStruct
	@serdeIgnoreUnexpectedKeys
	static struct CodeActionLiteralSupport
	{
		RequiredValueSet!CodeActionKind codeActionKind;
	}

	@serdeFallbackStruct
	@serdeIgnoreUnexpectedKeys
	static struct ResolveSupport
	{
		string[] properties;
	}


	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!CodeActionLiteralSupport codeActionLiteralSupport;
	@serdeOptional Optional!bool isPreferredSupport;
	@serdeOptional Optional!bool disabledSupport;
	@serdeOptional Optional!bool dataSupport;
	@serdeOptional Optional!ResolveSupport resolveSupport;
	@serdeOptional Optional!bool honorsChangeAnnotations;
}

@serdeFallbackStruct
struct CodeActionOptions
{
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!(CodeActionKind[]) codeActionKinds;
	@serdeOptional Optional!bool resolveProvider;
}

@serdeFallbackStruct
struct CodeActionRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!(CodeActionKind[]) codeActionKinds;
	@serdeOptional Optional!bool resolveProvider;
}

@serdeFallbackStruct
@allowedMethods("textDocument/codeAction")
struct CodeActionParams
{
	TextDocumentIdentifier textDocument;
	TextRange range;
	CodeActionContext context;
}

@serdeEnumProxy!string
enum CodeActionKind : string
{
	empty = "",
	quickfix = "quickfix",
	refactor = "refactor",
	refactorExtract = "refactor.extract",
	refactorInline = "refactor.inline",
	refactorRewrite = "refactor.rewrite",
	source = "source",
	sourceOrganizeImports = "source.organizeImports",
}

@serdeFallbackStruct
struct CodeActionContext
{
	Diagnostic[] diagnostics;
	@serdeOptional Optional!(CodeActionKind[]) only;
}

@serdeFallbackStruct
struct CodeAction
{
	this(Command command)
	{
		title = command.title;
		this.command = command;
	}

	this(Command command, CodeActionKind kind)
	{
		title = command.title;
		this.command = command;
		this.kind = kind;
	}

	this(string title, JsonValue[string] data)
	{
		this.title = title;
		this.data = JsonValue(data);
	}

	this(string title, JsonValue[string] data, CodeActionKind kind)
	{
		this.title = title;
		this.data = JsonValue(data);
		this.kind = kind;
	}

	this(string title, WorkspaceEdit edit)
	{
		this.title = title;
		this.edit = edit;
	}

	this(string title, WorkspaceEdit edit, CodeActionKind kind)
	{
		this.title = title;
		this.edit = edit;
		this.kind = kind;
	}

	/// Extension that reads {"id"} from the custom JSON data.
	Optional!string id()
	{
		return readData!string("id");
	}

	/// Extension that reads {"uri"} from the custom JSON data.
	Optional!string uri()
	{
		return readData!string("uri");
	}

	Optional!T readData(T)(string key)
	{
		if (data.isNone)
			return Optional!T.init;

		auto v = data.deref;
		return v.match!(
			(StringMap!JsonValue s) {
				if (auto v = key in s) {
					return (*v).match!(
						(T v) => Optional!T(v),
						(_) => Optional!T.init
					);
				}
				return Optional!T.init;
			},
			(_) => Optional!T.init
		);
	}

	@serdeFallbackStruct
	@serdeIgnoreUnexpectedKeys
	static struct Disabled
	{
		string reason;
	}

	string title;
	@serdeOptional Optional!CodeActionKind kind;
	@serdeOptional Optional!(Diagnostic[]) diagnostics;
	@serdeOptional Optional!bool isPreferred;
	@serdeOptional Optional!Disabled disabled;
	@serdeOptional Optional!WorkspaceEdit edit;
	@serdeOptional Optional!Command command;
	@serdeOptional OptionalJsonValue data;
}

@serdeFallbackStruct
struct CodeLensClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct CodeLensOptions
{
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!bool resolveProvider;
}

@serdeFallbackStruct
struct CodeLensRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!bool resolveProvider;
}

@serdeFallbackStruct
@allowedMethods("textDocument/codeLens")
struct CodeLensParams
{
	TextDocumentIdentifier textDocument;
}

@serdeFallbackStruct
struct CodeLens
{
	TextRange range;
	@serdeOptional Optional!Command command;
	@serdeOptional OptionalJsonValue data;
}

@serdeFallbackStruct
struct CodeLensWorkspaceClientCapabilities
{
	@serdeOptional Optional!bool refreshSupport;
}

@serdeFallbackStruct
struct DocumentLinkClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!bool tooltipSupport;
}

@serdeFallbackStruct
struct DocumentLinkOptions
{
	mixin WorkDoneProgressOptions;

	bool resolveProvider;
}

@serdeFallbackStruct
struct DocumentLinkRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;

	bool resolveProvider;
}

@serdeFallbackStruct
@allowedMethods("textDocument/documentLink")
struct DocumentLinkParams
{
	TextDocumentIdentifier textDocument;
}

@serdeFallbackStruct
struct DocumentLink
{
	TextRange range;
	@serdeOptional Optional!DocumentUri target;
	@serdeOptional Optional!string tooltip;
	@serdeOptional OptionalJsonValue data;
}

@serdeFallbackStruct
struct DocumentColorClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct DocumentColorOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct DocumentColorRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin StaticRegistrationOptions;
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/documentColor")
struct DocumentColorParams
{
	TextDocumentIdentifier textDocument;
}

@serdeFallbackStruct
struct ColorInformation
{
	TextRange range;
	Color color;
}

@serdeFallbackStruct
struct Color
{
	double red = 0;
	double green = 0;
	double blue = 0;
	double alpha = 1;
}

@serdeFallbackStruct
@allowedMethods("textDocument/colorPresentation")
struct ColorPresentationParams
{
	TextDocumentIdentifier textDocument;
	Color color;
	TextRange range;
}

@serdeFallbackStruct
struct ColorPresentation
{
	string label;
	@serdeOptional Optional!TextEdit textEdit;
	@serdeOptional Optional!(TextEdit[]) additionalTextEdits;
}

@serdeFallbackStruct
struct DocumentFormattingClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct DocumentFormattingOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct DocumentFormattingRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/formatting")
struct DocumentFormattingParams
{
	TextDocumentIdentifier textDocument;
	FormattingOptions options;
}

@serdeFallbackStruct
struct FormattingOptions
{
	int tabSize;
	bool insertSpaces;
	@serdeOptional Optional!bool trimTrailingWhitespace;
	@serdeOptional Optional!bool insertFinalNewline;
	@serdeOptional Optional!bool trimFinalNewlines;
	@serdeOptional OptionalJsonValue data;
}

@serdeFallbackStruct
struct DocumentRangeFormattingClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct DocumentRangeFormattingOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct DocumentRangeFormattingRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/rangeFormatting")
struct DocumentRangeFormattingParams
{
	TextDocumentIdentifier textDocument;
	TextRange range;
	FormattingOptions options;
}

@serdeFallbackStruct
struct DocumentOnTypeFormattingClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct DocumentOnTypeFormattingOptions
{
	string firstTriggerCharacter;
	@serdeOptional Optional!(string[]) moreTriggerCharacter;
}

@serdeFallbackStruct
struct DocumentOnTypeFormattingRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;

	string firstTriggerCharacter;
	@serdeOptional Optional!(string[]) moreTriggerCharacter;
}

@serdeFallbackStruct
@allowedMethods("textDocument/onTypeFormatting")
struct DocumentOnTypeFormattingParams
{
	TextDocumentIdentifier textDocument;
	Position position;
	string ch;
	FormattingOptions options;
}

@serdeEnumProxy!int
enum PrepareSupportDefaultBehavior
{
	identifier = 1
}

@serdeFallbackStruct
struct RenameClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!bool prepareSupport;
	@serdeOptional Optional!PrepareSupportDefaultBehavior prepareSupportDefaultBehavior;
	@serdeOptional Optional!bool honorsChangeAnnotations;
}

@serdeFallbackStruct
struct RenameOptions
{
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!bool prepareProvider;
}

@serdeFallbackStruct
struct RenameRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!bool prepareProvider;
}

@serdeFallbackStruct
@allowedMethods("textDocument/rename")
struct RenameParams
{
	TextDocumentIdentifier textDocument;
	Position position;
	string newName;
}

@serdeFallbackStruct
@allowedMethods("textDocument/prepareRename")
struct PrepareRenameParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct FoldingRangeClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!uint rangeLimit;
	@serdeOptional Optional!bool lineFoldingOnly;
}

@serdeFallbackStruct
struct FoldingRangeOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct FoldingRangeRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
	mixin StaticRegistrationOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/foldingRange")
struct FoldingRangeParams
{
	TextDocumentIdentifier textDocument;
}

@serdeEnumProxy!string
enum FoldingRangeKind : string
{
	comment = "comment",
	imports = "imports",
	region = "region"
}

@serdeFallbackStruct
struct FoldingRange
{
	uint startLine;
	uint endLine;
	@serdeOptional Optional!uint startCharacter;
	@serdeOptional Optional!uint endCharacter;
	@serdeOptional Optional!FoldingRangeKind kind;
}

unittest
{
	FoldingRange r;
	r.startLine = 1;
	r.endLine = 10;
	r.startCharacter = 4;
	r.endCharacter = 2;
	r.kind = FoldingRangeKind.imports;

	assert(serializeJson([r]) == `[{"startLine":1,"endLine":10,"startCharacter":4,"endCharacter":2,"kind":"imports"}]`);

	r.kind = cast(FoldingRangeKind)"custom";

	assert(serializeJson([r]) == `[{"startLine":1,"endLine":10,"startCharacter":4,"endCharacter":2,"kind":"custom"}]`);
}

@serdeFallbackStruct
struct SelectionRangeClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct SelectionRangeOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct SelectionRangeRegistrationOptions
{
	mixin WorkDoneProgressOptions;
	mixin TextDocumentRegistrationOptions;
	mixin StaticRegistrationOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/selectionRange")
struct SelectionRangeParams
{
	TextDocumentIdentifier textDocument;
	Position[] positions;
}

@serdeFallbackStruct
struct SelectionRange
{
	TextRange range;
	@serdeOptional OptionalJsonValue parent;
}

@serdeFallbackStruct
struct CallHierarchyClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct CallHierarchyOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct CallHierarchyRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
	mixin StaticRegistrationOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/prepareCallHierarchy")
struct CallHierarchyPrepareParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct CallHierarchyItem
{
	string name;
	SymbolKind kind;
	@serdeOptional Optional!(SymbolTag[]) tags;
	@serdeOptional Optional!string detail;
	DocumentUri uri;
	TextRange range;
	TextRange selectionRange;
	@serdeOptional OptionalJsonValue data;
}

@serdeFallbackStruct
@allowedMethods("callHierarchy/incomingCalls")
struct CallHierarchyIncomingCallsParams
{
	CallHierarchyItem item;
}

@serdeFallbackStruct
struct CallHierarchyIncomingCall
{
	CallHierarchyItem from;
	TextRange[] fromRanges;
}

@serdeFallbackStruct
@allowedMethods("callHierarchy/outgoingCalls")
struct CallHierarchyOutgoingCallsParams
{
	CallHierarchyItem item;
}

@serdeFallbackStruct
struct CallHierarchyOutgoingCall
{
	CallHierarchyItem to;
	TextRange[] fromRanges;
}

@serdeEnumProxy!string
enum SemanticTokenTypes : string
{
	namespace = "namespace",
	type = "type",
	class_ = "class",
	enum_ = "enum",
	interface_ = "interface",
	struct_ = "struct",
	typeParameter = "typeParameter",
	parameter = "parameter",
	variable = "variable",
	property = "property",
	enumMember = "enumMember",
	event = "event",
	function_ = "function",
	method = "method",
	macro_ = "macro",
	keyword = "keyword",
	modifier = "modifier",
	comment = "comment",
	string = "string",
	number = "number",
	regexp = "regexp",
	operator = "operator"
}

@serdeEnumProxy!string
enum SemanticTokenModifiers : string
{
	declaration = "declaration",
	definition = "definition",
	readonly = "readonly",
	static_ = "static",
	deprecated_ = "deprecated",
	abstract_ = "abstract",
	async = "async",
	modification = "modification",
	documentation = "documentation",
	defaultLibrary = "defaultLibrary"
}

@serdeEnumProxy!string
enum TokenFormat : string
{
	relative = "relative"
}

@serdeFallbackStruct
struct SemanticTokensLegend
{
	string[] tokenTypes;
	string[] tokenModifiers;
}

@serdeFallbackStruct
struct SemanticTokensRange
{
}

@serdeFallbackStruct
struct SemanticTokensFull
{
	@serdeOptional Optional!bool delta;
}


@serdeFallbackStruct
struct SemanticTokensClientCapabilities
{
	@serdeIgnoreUnexpectedKeys
	static struct Requests
	{
		@serdeOptional Variant!(void, bool, SemanticTokensRange) range;
		@serdeOptional Variant!(void, bool, SemanticTokensFull) full;
	}

	@serdeOptional Optional!bool dynamicRegistration;
	Requests requests;
	string[] tokenTypes;
	string[] tokenModifiers;
	TokenFormat[] formats;
	@serdeOptional Optional!bool overlappingTokenSupport;
	@serdeOptional Optional!bool multilineTokenSupport;
}

@serdeFallbackStruct
struct SemanticTokensOptions
{
	mixin WorkDoneProgressOptions;

	SemanticTokensLegend legend;
	@serdeOptional Variant!(void, bool, SemanticTokensRange) range;
	@serdeOptional Variant!(void, bool, SemanticTokensFull) full;
}

@serdeFallbackStruct
struct SemanticTokensRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
	mixin StaticRegistrationOptions;

	SemanticTokensLegend legend;
	@serdeOptional Variant!(void, bool, SemanticTokensRange) range;
	@serdeOptional Variant!(void, bool, SemanticTokensFull) full;
}

@serdeFallbackStruct
@allowedMethods("textDocument/semanticTokens/full")
struct SemanticTokensParams
{
	TextDocumentIdentifier textDocument;
}

@serdeFallbackStruct
struct SemanticTokens
{
	@serdeOptional Optional!string resultId;
	uint[] data;
}

@serdeFallbackStruct
struct SemanticTokensPartialResult
{
	uint[] data;
}

@serdeFallbackStruct
@allowedMethods("textDocument/semanticTokens/full/delta")
struct SemanticTokensDeltaParams
{
	TextDocumentIdentifier textDocument;
	string previousResultId;
}

@serdeFallbackStruct
struct SemanticTokensDelta
{
	string resultId;
	SemanticTokensEdit[] edits;
}

@serdeFallbackStruct
struct SemanticTokensEdit
{
	uint start;
	uint deleteCount;
	@serdeOptional Optional!(uint[]) data;
}

@serdeFallbackStruct
struct SemanticTokensDeltaPartialResult
{
	SemanticTokensEdit[] edits;
}

@serdeFallbackStruct
@allowedMethods("textDocument/semanticTokens/range")
struct SemanticTokensRangeParams
{
	TextDocumentIdentifier textDocument;
	TextRange range;
}

@serdeFallbackStruct
struct SemanticTokensWorkspaceClientCapabilities
{
	@serdeOptional Optional!bool refreshSupport;
}


@serdeFallbackStruct
struct LinkedEditingRangeClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct LinkedEditingRangeOptions
{
	mixin WorkDoneProgressOptions;
}

@serdeFallbackStruct
struct LinkedEditingRangeRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
	mixin StaticRegistrationOptions;
}

@serdeFallbackStruct
@allowedMethods("textDocument/linkedEditingRange")
struct LinkedEditingRangeParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct LinkedEditingRanges
{
	TextRange[] ranges;
	@serdeOptional Optional!string wordPattern;
}

@serdeFallbackStruct
struct ExecuteCommandClientCapabilities
{
	@serdeOptional Optional!bool dynamicRegistration;
}

@serdeFallbackStruct
struct ExecuteCommandOptions
{
	string[] commands;
}

@serdeFallbackStruct
struct ExecuteCommandRegistrationOptions
{
	string[] commands;
}

@serdeFallbackStruct
@allowedMethods("workspace/executeCommand")
struct ExecuteCommandParams
{
	string command;
	@serdeOptional Optional!(JsonValue[]) arguments;
}

@serdeFallbackStruct
@allowedMethods("workspace/applyEdit")
struct ApplyWorkspaceEditParams
{
	@serdeOptional Optional!string label;
	WorkspaceEdit edit;
}

@serdeFallbackStruct
struct ApplyWorkspaceEditResponse
{
	bool applied;
	@serdeOptional Optional!string failureReason;
	@serdeOptional Optional!uint failedChange;
}

@serdeFallbackStruct
struct WorkspaceFolder
{
	string uri;
	string name;
}

@serdeFallbackStruct
@allowedMethods("workspace/didChangeWorkspaceFolders")
struct DidChangeWorkspaceFoldersParams
{
	WorkspaceFoldersChangeEvent event;
}

@serdeFallbackStruct
struct WorkspaceFoldersChangeEvent
{
	WorkspaceFolder[] added;
	WorkspaceFolder[] removed;
}

@serdeEnumProxy!string
enum TraceValue : string
{
	off = "off",
	messages = "messages",
	verbose = "verbose",
}

@serdeFallbackStruct
@allowedMethods("$/setTrace")
struct SetTraceParams
{
	TraceValue value;
}

@serdeFallbackStruct
@allowedMethods("$/logTrace")
struct LogTraceParams
{
	string message;
	@serdeOptional Optional!string verbose;
}

unittest
{
	StringMap!JsonValue s;
	assert(serializeJson(s) == `{}`);
	s["hello"] = JsonValue("world");
	assert(serializeJson(s) == `{"hello":"world"}`);
}

unittest
{
	import std.traits;
	import mir.algebraic : Algebraic;

	bool hasSerdeEnumProxy(Args...)()
	{
		bool ret = false;
		static foreach (Arg; Args)
		{
			static if (is(Arg == enum)
				&& hasUDA!(Arg, serdeProxyCast))
				ret = true;
		}
		return ret;
	}

	void LintVariantArgs(alias T, string member, string memberDisplay, Args...)()
	{
		static if (hasSerdeEnumProxy!Args)
		{
			static if (Args.length != 2
				|| !(is(Args[0] == void) || is(Args[0] == typeof(null))))
			{
				// https://github.com/libmir/mir-ion/issues/36
				pragma(msg, "WARNING: known-broken deserialization on Variant!", Args.stringof, "\n\ton field ", memberDisplay);
			}
		}

		static if (is(Args[0] == void) && !hasUDA!(__traits(getMember, T, member), serdeOptional))
		{
			pragma(msg, "WARNING: Optional doesn't have @serdeOptional annotation!\n\ton field ", memberDisplay);
		}
	}

	void LintStruct(alias T)()
	{
		static foreach (member; __traits(allMembers, T))
		{{
			static if (is(__traits(getMember, T, member) == struct))
			{
				LintStruct!(__traits(getMember, T, member));
			}
			else static if (is(typeof(__traits(getMember, T, member))))
			{
				static if (is(typeof(__traits(getMember, T, member))
					: Algebraic!Args, Args...))
				{
					LintVariantArgs!(T, member, T.stringof ~ "." ~ member, Args);
				}
			}
		}}
	}

	LintStruct!(served.lsp.protocol);
}
