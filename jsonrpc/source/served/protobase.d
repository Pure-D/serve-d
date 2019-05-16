module served.protobase;

import std.conv;
import std.json;
import std.traits;
import std.meta;

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

	ref T get()
	{
		return value;
	}

	alias value this;
}

mixin template StrictOptionalSerializer()
{
	import painlessjson : defaultToJSON, SerializedName, SerializedToName;
	import std.traits : hasUDA, getUDAs;

	const JSONValue _toJSON()
	{
		JSONValue[string] ret = defaultToJSON(this).object;
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
		if (val.type == JSON_TYPE.ARRAY)
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
		if (val.type == JSON_TYPE.STRING)
		{
			isString = true;
			str = val.str;
		}
		else if (val.type == JSON_TYPE.INTEGER)
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

	const JSONValue _toJSON()
	{
		JSONValue[string] ret = [
			"code": JSONValue(cast(int)code),
			"message": JSONValue(message),
			"data": data
		];
		return JSONValue(ret);
	}

	static ResponseError _fromJSON(JSONValue val)
	{
		ResponseError ret;
		auto obj = val.object;
		if (auto code = "code" in obj)
			ret.code = cast(ErrorCode) code.integer;
		if (auto message = "message" in obj)
			ret.message = message.str;
		if (auto data = "data" in obj)
			ret.data = *data;
		return ret;
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
	JSONValue result;
	Optional!ResponseError error;
}
