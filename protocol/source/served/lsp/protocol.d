/**
Implements the various LSP type definitions

Standards: LSP v3.16 https://microsoft.github.io/language-server-protocol/specifications/specification-3-16/
*/
module served.lsp.protocol;

import std.conv;
import std.meta;
import std.traits;

import mir.serde;

import mir.algebraic : MirAlgebraic = Algebraic;
public import mir.algebraic : isVariant = isLikeVariant, match, Nullable;

public import served.lsp.jsonops;

version (unittest)
	import std.exception;

template Variant(T...)
{
	@serdeProxy!(MirAlgebraic!T)
	struct Variant
	{
		static foreach (S; T)
		{
			static if (!is(S : NoneType)
				&& is(S == struct)
				&& !hasUDA!(S, serdeFallbackStruct)
				&& !isVariant!S)
				static assert(false, "included " ~ S.stringof ~ " in Variant, which is not a serdeFallbackStruct");
		}

		// using algebraic because its .init value is predictable (first type)
		MirAlgebraic!T value;
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
				value = typeof(value)(rhs);
			return this;
		}

		bool serdeIgnoreOut() const
		{
			return value.match!((v) {
				static if (is(typeof(v) : NoneType)
					|| __traits(compiles, v.serdeIgnoreOut))
					return v.serdeIgnoreOut;
				else
					return false;
			});
		}
	}
}

static assert(isVariant!(Variant!(int, string)),
	"isVariant suffers from D issue 21975, please upgrade compiler (fixed since frontend 2.100.0)");

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

	MirAlgebraic!AllowedTypes value;
	alias value this;

	this(MirAlgebraic!AllowedTypes v)
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

		bool[commonKeys.length] hasRequired;

		auto struct_ = value.get!(IonStruct).withSymbols(symbolTable);
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

/// For use with Variant to not serialize anything at all.
struct NoneType
{
	enum serdeIgnoreOut = true;
	void serialize(S)(ref S serializer) const { assert(false, "serialize called on NoneType"); }
}

alias Optional(T) = Variant!(NoneType, T);
alias OptionalJsonValue = Optional!JsonValue;
template TypeFromOptional(T)
{
	alias Reduced = FilterNonNoneType!(T.AllowedTypes);
	static assert(Reduced.length == 1, "got optional without exactly a single type: " ~ T.AllowedTypes.stringof);
	static assert(!isVariant!(Reduced[0]), "failed to reduce " ~ T.stringof ~ " - " ~ Reduced[0].stringof);
	alias TypeFromOptional = Reduced[0];
}

private template FilterNonNoneType(T...)
{
	static if (!T.length)
		alias FilterNonNoneType = AliasSeq!();
	else static if (is(immutable T[0] == immutable NoneType))
		alias FilterNonNoneType = AliasSeq!(FilterNonNoneType!(T[1 .. $]));
	else
		alias FilterNonNoneType = AliasSeq!(T[0], FilterNonNoneType!(T[1 .. $]));
}

bool isNone(T)(T v)
if (isVariant!T)
{
	return v.match!(
		(NoneType none) => true,
		_ => false
	);
}

///
auto deref(T)(scope return inout T v)
if (isVariant!T)
{
	return v.match!(
		(NoneType none) {
			throw new Exception("Attempted to get unset " ~ T.stringof);
			return assert(false); // changes return type to bottom_t
		},
		ret => ret
	);
}

/// ditto
JsonValue deref(scope return inout OptionalJsonValue v)
{
	if (v.value._is!NoneType)
		throw new Exception("Attempted to get unset JsonValue");
	return v.value.get!JsonValue;
}

/// Returns the deref value from this optional or TypeFromOptional!T.init if
/// set to none.
TypeFromOptional!T orDefault(T)(scope return T v)
if (isVariant!T)
{
	return v.match!(
		(NoneType none) => TypeFromOptional!T.init,
		ret => ret
	);
}

///
T expect(T, ST)(ST v)
if (isVariant!ST)
{
	return v.match!(
		(NoneType none) {
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
void nullify(T)(scope return ref T v)
if (isVariant!T)
{
	v = NoneType.init;
}

///
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

	optInt.nullify();
	optString1.nullify();
	optString2.nullify();

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
struct ValueSet(T)
{
	T[] valueSet;
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
	Variant!(long, string) value;
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

	static RequestToken random()
	{
		version (unittest)
			char[16] buffer; // make sure uninitialized buffers are caught in tests
		else
			char[16] buffer = void;

		randomSerialized(buffer);
		return RequestToken(buffer[1 .. $ - 1].idup);
	}

	static void randomSerialized(char[] buffer)
	in(buffer.length > 2)
	{
		import std.random : uniform;

		static immutable letters = `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz`;

		buffer[0] = '"';
		for (int i = 1; i < buffer.length; i++)
			buffer[i] = letters[uniform(0, $)];
		buffer[$ - 1] = '"';
	}

	static RequestToken randomAndSerialized(char[] buffer)
	{
		randomSerialized(buffer);
		return RequestToken(buffer[1 .. $ - 1].idup);
	}
}

unittest
{
	assert(deserializeJson!RequestToken(`"hello"`) == RequestToken("hello"));
	assert(deserializeJson!RequestToken(`4000`) == RequestToken(4000));

	assert(`"hello"` == RequestToken("hello").serializeJson);
	assert(`4000` == RequestToken(4000).serializeJson);

	auto tok = RequestToken.random();
	auto other = RequestToken.random();
	assert(tok.value.get!string.length > 10);
	assert(tok.value.get!string[0 .. 5] != tok.value.get!string[5 .. 10]);
	assert(tok.value.get!string != other.value.get!string);

	char[16] buf;
	tok = RequestToken.randomAndSerialized(buf[]);
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

	this(Nullable!RequestToken id, JsonValue result)
	{
		this.id = id;
		this.result = result;
	}

	this(Nullable!RequestToken id, ResponseError error)
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
	@serdeOptional Nullable!RequestToken id;
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
	if (!res.id.isNone)
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
	Optional!RequestToken id;
	/// empty string/null if not set, otherwise JSON string of result
	string resultJson;
	///
	Optional!ResponseError error;
}

alias DocumentUri = string;

@serdeFallbackStruct
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
struct LogMessageParams
{
	MessageType type;
	string message;
}

alias ProgressToken = Variant!(int, string);

@serdeFallbackStruct
struct WorkDoneProgressCreateParams
{
	ProgressToken token;
}

@serdeFallbackStruct
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
	string languageId;
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
struct InitializeParams
{
	Variant!(typeof(null), int) processId;
	@serdeOptional Optional!string rootPath;
	DocumentUri rootUri;
	@serdeOptional OptionalJsonValue initializationOptions;
	ClientCapabilities capabilities;
	@serdeOptional Optional!string trace;
	@serdeOptional Variant!(NoneType, typeof(null), WorkspaceFolder[]) workspaceFolders;
	@serdeOptional Optional!InitializeParamsClientInfo clientInfo;
	@serdeOptional Optional!string locale;
}

unittest
{
	Variant!(NoneType, typeof(null), WorkspaceFolder[]) workspaceFolders;
	assert(workspaceFolders.serdeIgnoreOut);
	workspaceFolders = null;
	assert(!workspaceFolders.serdeIgnoreOut);

	InitializeParams p = {
		processId: 1234,
		rootUri: "file:///root/path",
		capabilities: ClientCapabilities.init
	};
	assert(p.serializeJson == `{"processId":1234,"rootUri":"file:///root/path","capabilities":{}}`, p.serializeJson);
}

@serdeFallbackStruct
struct InitializeParamsClientInfo
{
	string name;
	@serdeKeys("version") Optional!string version_;
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
	@serdeKeys("version") Optional!string version_;
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

@serdeFallbackStruct
struct ServerInfo
{
	string name;
	@serdeKeys("version") Optional!string version_;
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
		@serdeOptional Optional!(ValueSet!CompletionItemTag) tagSupport;
		@serdeOptional Optional!bool insertReplaceSupport;
		@serdeOptional Optional!ResolveSupport resolveSupport;
		@serdeOptional Optional!(ValueSet!InsertTextMode) insertTextModeSupport;
		@serdeOptional Optional!bool labelDetailsSupport;
	}

	@serdeOptional Optional!bool dynamicRegistration;
	@serdeOptional Optional!CompletionItemCapabilities completionItem;
	@serdeOptional Optional!(ValueSet!CompletionItemKind) completionItemKind;
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
	@serdeOptional Variant!(NoneType, bool, SaveOptions) save;
}

@serdeFallbackStruct
struct ServerCapabilities
{
	@serdeOptional Variant!(NoneType, TextDocumentSyncOptions, TextDocumentSyncKind) textDocumentSync;
	@serdeOptional Variant!(NoneType, CompletionOptions) completionProvider;
	@serdeOptional Variant!(NoneType, bool, HoverOptions) hoverProvider;
	@serdeOptional Variant!(NoneType, SignatureHelpOptions) signatureHelpProvider;
	@serdeOptional Variant!(NoneType, bool, StructVariant!(DeclarationOptions, DeclarationRegistrationOptions)) declarationProvider;
	@serdeOptional Variant!(NoneType, bool, DefinitionOptions) definitionProvider;
	@serdeOptional Variant!(NoneType, bool, StructVariant!(TypeDefinitionOptions, TypeDefinitionRegistrationOptions)) typeDefinitionProvider;
	@serdeOptional Variant!(NoneType, bool, StructVariant!(ImplementationOptions, ImplementationRegistrationOptions)) implementationProvider;
	@serdeOptional Variant!(NoneType, bool, ReferenceOptions) referencesProvider;
	@serdeOptional Variant!(NoneType, bool, DocumentHighlightOptions) documentHighlightProvider;
	@serdeOptional Variant!(NoneType, bool, DocumentSymbolOptions) documentSymbolProvider;
	@serdeOptional Variant!(NoneType, bool, CodeActionOptions) codeActionProvider;
	@serdeOptional Variant!(NoneType, CodeLensOptions) codeLensProvider;
	@serdeOptional Variant!(NoneType, DocumentLinkOptions) documentLinkProvider;
	@serdeOptional Variant!(NoneType, bool, StructVariant!(DocumentColorOptions, DocumentColorRegistrationOptions)) colorProvider;
	@serdeOptional Variant!(NoneType, bool, DocumentFormattingOptions) documentFormattingProvider;
	@serdeOptional Variant!(NoneType, bool, DocumentRangeFormattingOptions) documentRangeFormattingProvider;
	@serdeOptional Variant!(NoneType, DocumentOnTypeFormattingOptions) documentOnTypeFormattingProvider;
	@serdeOptional Variant!(NoneType, bool, RenameOptions) renameProvider;
	@serdeOptional Variant!(NoneType, bool, StructVariant!(FoldingRangeOptions, FoldingRangeRegistrationOptions)) foldingRangeProvider;
	@serdeOptional Variant!(NoneType, ExecuteCommandOptions) executeCommandProvider;
	@serdeOptional Variant!(NoneType, bool, StructVariant!(SelectionRangeOptions, SelectionRangeRegistrationOptions)) selectionRangeProvider;
	@serdeOptional Variant!(NoneType, bool, StructVariant!(LinkedEditingRangeOptions, LinkedEditingRangeRegistrationOptions)) linkedEditingRangeProvider;
	@serdeOptional Variant!(NoneType, bool, StructVariant!(CallHierarchyOptions, CallHierarchyRegistrationOptions)) callHierarchyProvider;
	@serdeOptional Variant!(NoneType, StructVariant!(SemanticTokensOptions, SemanticTokensRegistrationOptions)) semanticTokensProvider;
	@serdeOptional Variant!(NoneType, bool, StructVariant!(MonikerOptions, MonikerRegistrationOptions)) monikerProvider;
	@serdeOptional Variant!(NoneType, bool, WorkspaceSymbolOptions) workspaceSymbolProvider;

	@serdeOptional Optional!ServerWorkspaceCapabilities workspace;
	@serdeOptional OptionalJsonValue experimental;
}

unittest
{
	CodeActionOptions cao = {
		codeActionKinds: [CodeActionKind.refactor, CodeActionKind.sourceOrganizeImports, cast(CodeActionKind)"CustomKind"]
	};
	ServerCapabilities cap = {
		textDocumentSync: TextDocumentSyncKind.incremental,
		codeActionProvider: cao
	};
	assert(cap.serializeJson == `{"textDocumentSync":2,"codeActionProvider":{"codeActionKinds":["refactor","source.organizeImports","CustomKind"]}}`, cap.serializeJson);
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
	@serdeOptional Variant!(NoneType, bool, string) changeNotifications;
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
struct CreateFileParams
{
	FileCreate[] files;
}

@serdeFallbackStruct
struct FileCreate
{
	string uri;
}

@serdeFallbackStruct
struct RenameFileParams
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
struct DeleteFileParams
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

@serdeFallbackStruct
struct DidChangeConfigurationParams
{
	JsonValue settings;
}

@serdeFallbackStruct
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
struct DidOpenTextDocumentParams
{
	TextDocumentItem textDocument;
}

@serdeFallbackStruct
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
struct DidSaveTextDocumentParams
{
	TextDocumentIdentifier textDocument;
	@serdeOptional Optional!string text;
}

@serdeFallbackStruct
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
	@serdeOptional Optional!(ValueSet!SymbolKind) symbolKind;
	@serdeOptional Optional!(ValueSet!SymbolTag) tagSupport;
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
struct WorkspaceSymbolParams
{
	string query;
}

@serdeFallbackStruct
struct PublishDiagnosticsClientCapabilities
{
	@serdeOptional Optional!bool relatedInformation;
	@serdeOptional Optional!(ValueSet!DiagnosticTag) tagSupport;
	@serdeOptional Optional!bool versionSupport;
	@serdeOptional Optional!bool codeDescriptionSupport;
	@serdeOptional Optional!bool dataSupport;
}

@serdeFallbackStruct
struct PublishDiagnosticsParams
{
	DocumentUri uri;
	Diagnostic[] diagnostics;
	@serdeKeys("version") Optional!int version_;
}

@serdeFallbackStruct
struct CompletionRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;

	@serdeOptional Optional!(string[]) triggerCharacters;
	bool resolveProvider;
}

@serdeFallbackStruct
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

	Variant!(NoneType, InsertReplaceEdit) var = v;
	assert(s.deserializeJson!(typeof(var)) == var);

	Variant!(NoneType, StructVariant!(TextEdit, InsertReplaceEdit)) var2 = v;
	assert(s.deserializeJson!(typeof(var2)) == var2);

	struct Struct
	{
		Variant!(NoneType, StructVariant!(TextEdit, InsertReplaceEdit)) edit;
	}

	Struct str;
	str.edit = v;
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
	@serdeOptional Variant!(NoneType, string, MarkupContent) documentation;
	@serdeOptional Optional!bool preselect;
	@serdeOptional Optional!string sortText;
	@serdeOptional Optional!string filterText;
	@serdeOptional Optional!string insertText;
	@serdeOptional Optional!InsertTextFormat insertTextFormat;
	@serdeOptional Optional!InsertTextMode insertTextMode;
	@serdeOptional Variant!(NoneType, StructVariant!(TextEdit, InsertReplaceEdit)) textEdit;
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
struct HoverParams
{
	TextDocumentIdentifier textDocument;
	Position position;
}

@serdeFallbackStruct
struct Hover
{
	Variant!MarkupContent contents;
	@serdeOptional Optional!TextRange range;
}

@serdeFallbackStruct
struct MarkedString
{
	string value;
	string language;
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
	@serdeKeys("version") Optional!string version_;
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
	@serdeOptional Variant!(NoneType, string, MarkupContent) documentation;
	@serdeOptional Optional!(ParameterInformation[]) parameters;
	@serdeOptional Optional!uint activeParameter;
}

@serdeFallbackStruct
struct ParameterInformation
{
	Variant!(string, uint[2]) label;
	@serdeOptional Variant!(NoneType, string, MarkupContent) documentation;
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
struct ReferenceParams
{
	TextDocumentIdentifier textDocument;
	Position position;
	ReferenceContext context;
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
	@serdeOptional Optional!(ValueSet!SymbolKind) symbolKind;
	@serdeOptional Optional!bool hierarchicalDocumentSymbolSupport;
	@serdeOptional Optional!(ValueSet!SymbolTag) tagSupport;
	@serdeOptional Optional!bool labelSupport;
}

@serdeFallbackStruct
struct DocumentSymbolOptions
{
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!string label;
}

@serdeFallbackStruct
struct DocumentSymbolRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;

	@serdeOptional Optional!string label;
}

@serdeFallbackStruct
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
		ValueSet!CodeActionKind codeActionKind;
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

	this(string title, WorkspaceEdit edit)
	{
		this.title = title;
		this.edit = edit;
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
struct RenameParams
{
	TextDocumentIdentifier textDocument;
	Position position;
	string newName;
}

@serdeFallbackStruct
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
	@serdeOptional Optional!string kind;
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
	string[] tokenmodifiers;
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
		@serdeOptional Variant!(NoneType, bool, SemanticTokensRange) range;
		@serdeOptional Variant!(NoneType, bool, SemanticTokensFull) full;
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
	@serdeOptional Variant!(NoneType, bool, SemanticTokensRange) range;
	@serdeOptional Variant!(NoneType, bool, SemanticTokensFull) full;
}

@serdeFallbackStruct
struct SemanticTokensRegistrationOptions
{
	mixin TextDocumentRegistrationOptions;
	mixin WorkDoneProgressOptions;
	mixin StaticRegistrationOptions;

	SemanticTokensLegend legend;
	@serdeOptional Variant!(NoneType, bool, SemanticTokensRange) range;
	@serdeOptional Variant!(NoneType, bool, SemanticTokensFull) full;
}

@serdeFallbackStruct
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
struct ExecuteCommandParams
{
	string command;
	@serdeOptional Optional!(JsonValue[]) arguments;
}

@serdeFallbackStruct
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

@serdeFallbackStruct
struct TraceParams
{
	string value;
}

unittest
{
	StringMap!JsonValue s;
	assert(serializeJson(s) == `{}`);
	s["hello"] = JsonValue("world");
	assert(serializeJson(s) == `{"hello":"world"}`);
}
