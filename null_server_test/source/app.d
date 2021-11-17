import core.time;

version (assert)
{
}
else
	static assert(false, "This test must be compiled with asserts on");

import core.thread;
import std.concurrency;
import std.conv;
import std.json;
import std.process;
import std.stdio;
import std.string;

void main(string[] args)
{
	version (Windows)
		string exePath = `.\null_server\null_server.exe`;
	else
		string exePath = `./null_server/null_server`;

	auto pipes = pipeProcess(exePath, Redirect.all);
	scope (exit)
	{
		pipes.stdin.close();
		pipes.stdout.close();
		pipes.stderr.close();
		wait(pipes.pid);
	}
	scope (failure)
		pipes.pid.kill(9);

	new Thread({
		foreach (line; pipes.stderr.byLine)
			stderr.writeln("Server: ", line);
	}).start();

	int id = pipes.sendRequest("initialize", JSONValue([
		"processId": JSONValue(thisProcessID),
		"rootUri": JSONValue(null),
		"capabilities": parseJSON(`{}`)
	]));
	auto response = pipes.readPacket(id);
	response.assertContainsJson(JSONValue([
		"result": JSONValue([
			"capabilities": JSONValue([
				"experimental": JSONValue("initialized null server")
			])
		])
	]));

	pipes.sendNotification("initialized", parseJSON(`{}`));

	id = pipes.sendRequest("dummy/testString", JSONValue("value"));
	response = pipes.readPacket(id);
	response.assertContainsJson(JSONValue([
		"error": JSONValue([
			"code": JSONValue(-32602)
		])
	]));

	id = pipes.sendRequest("dummy/testString", JSONValue([JSONValue("myInputValue")]));
	response = pipes.readPacket(id);
	response.assertContainsJson(JSONValue(["result": JSONValue("myInputValue_ok")]));

	id = pipes.sendRequest("dummy/testString", JSONValue([JSONValue("too many"), JSONValue("args")]));
	response = pipes.readPacket(id);
	response.assertContainsJson(JSONValue([
		"error": JSONValue([
			"code": JSONValue(-32602)
		])
	]));

	id = pipes.sendRequest("dummy/testString", JSONValue([JSONValue(5)]));
	response = pipes.readPacket(id);
	response.assertContainsJson(JSONValue([
		"error": JSONValue([
			"code": JSONValue(-32602)
		])
	]));

	id = pipes.sendRequest("dummy/testString", JSONValue([
		"param": JSONValue("param") // this might be supported eventually
	]));
	response = pipes.readPacket(id);
	response.assertContainsJson(JSONValue([
		"error": JSONValue([
			"code": JSONValue(-32602)
		])
	]));

	id = pipes.sendRequest("dummy/testStruct", JSONValue([
		"name": JSONValue("myName"),
		"num": JSONValue(7),
		"arr": JSONValue([JSONValue("myArr")]),
	]));
	response = pipes.readPacket(id);
	response.assertContainsJson(JSONValue([
		"result": JSONValue([
			"ret": JSONValue("myName_ok"),
			"a": JSONValue(8),
			"x": JSONValue([JSONValue("myArr")]),
		])
	]));

	id = pipes.sendRequest("dummy/testJson", JSONValue([
		"name": JSONValue("myName"),
		"num": JSONValue(7),
		"arr": JSONValue([JSONValue("myArr")]),
	]));
	response = pipes.readPacket(id);
	response.assertContainsJson(JSONValue([
		"result": JSONValue([
			"orig": JSONValue([
				"name": JSONValue("myName"),
				"num": JSONValue(7),
				"arr": JSONValue([JSONValue("myArr")]),
			]),
			"extra": JSONValue("hello")
		])
	]));

	id = pipes.sendRequest("dummy/testVoid");
	response = pipes.readPacket(id);
	response.assertContainsJson(JSONValue([
		"result": JSONValue(4)
	]));

	pipes.sendNotification("dummy/testNotify");
	response = pipes.readPacket();
	response.assertContainsJson(JSONValue([
		"method": JSONValue("dummy/replyNotify")
	]));

	id = pipes.sendRequest("dummy/testPartial", JSONValue([
		"partialResultToken": JSONValue(1337)
	]));
	response = pipes.readPacket();
	response.assertContainsJson(JSONValue([
		"method": JSONValue("$/progress"),
		"params": JSONValue([
			"token": JSONValue(1337),
			"value": JSONValue([
				JSONValue(1),
				JSONValue(2)
			])
		])
	]));
	response = pipes.readPacket();
	response.assertContainsJson(JSONValue([
		"method": JSONValue("$/progress"),
		"params": JSONValue([
			"token": JSONValue(1337),
			"value": JSONValue([
				JSONValue(3),
				JSONValue(4)
			])
		])
	]));
	response = pipes.readPacket();
	response.assertContainsJson(JSONValue([
		"method": JSONValue("$/progress"),
		"params": JSONValue([
			"token": JSONValue(1337),
			"value": JSONValue([
				JSONValue(5),
				JSONValue(6)
			])
		])
	]));
	response = pipes.readPacket(id);
	response.assertContainsJson(JSONValue([
		"result": parseJSON(`[]`)
	]));

	writeln("[success] All tests OK! Shutting down server...");

	pipes.sendRequest("shutdown");
	pipes.sendNotification("exit");
}

void assertContainsJson(JSONValue doesThis, JSONValue containAllOfThis, int maxDepth = 50)
{
	assert(maxDepth > 0, "max depth reached");
	assert(doesThis.type == containAllOfThis.type);
	final switch (doesThis.type)
	{
	case JSONType.string:
		assert(doesThis.str == containAllOfThis.str);
		break;
	case JSONType.integer:
		assert(doesThis.integer == containAllOfThis.integer);
		break;
	case JSONType.uinteger:
		assert(doesThis.uinteger == containAllOfThis.uinteger);
		break;
	case JSONType.float_:
		assert(doesThis.floating == containAllOfThis.floating);
		break;
	case JSONType.array:
		assert(doesThis.array.length == containAllOfThis.array.length);
		foreach (i, b; containAllOfThis.array)
			doesThis.array[i].assertContainsJson(b, maxDepth - 1);
		break;
	case JSONType.object:
		foreach (key, value; containAllOfThis.object)
		{
			auto a = key in doesThis.object;
			assert(a);
			(*a).assertContainsJson(value, maxDepth - 1);
		}
		break;
	case JSONType.null_:
	case JSONType.true_:
	case JSONType.false_:
		return;
	}
}

bool startsWithSI(scope const(char)[] doesThis, scope const(char)[] startWithThis)
{
	import std.uni : sicmp;

	return doesThis.length >= startWithThis.length
		&& sicmp(doesThis[0 .. startWithThis.length], startWithThis) == 0;
}

auto terminateTimeout(ref ProcessPipes pipes, Duration timeout = 5.seconds)
{
	static struct ScopeGuard
	{
		Tid _t;

		this(shared ProcessPipes* pipes, Duration timeout)
		{
			_t = spawn(&killerImpl, pipes, timeout);
		}

		~this()
		{
			send(_t, true);
		}

		static void killerImpl(shared ProcessPipes* pipes, Duration timeout)
		{
			bool finished;
			receiveTimeout(timeout, (bool b) {
				finished = b;
			});

			if (finished)
				return;

			ProcessPipes p = cast()*pipes;
			try
			{
				p.pid.kill();
				p.stderr.close();
				p.stdout.close();
				p.stdin.close();
			}
			catch (Exception e)
			{
				writeln("Killing process failed: ", e);
				assert(false);
			}
		}
	}

	return ScopeGuard(cast(shared)&pipes, timeout);
}

__gshared int idCounter;
int sendRequest(ref ProcessPipes pipes, string method, JSONValue params = JSONValue.init)
{
	int id;
	JSONValue json = JSONValue([
		"jsonrpc": JSONValue("2.0"),
		"id": JSONValue(id = ++idCounter),
		"method": JSONValue(method)
	]);
	if (params != JSONValue.init)
		json["params"] = params;
	stderr.writeln("--> #", id, " method ", method);
	pipes.sendPacketRaw(json.toString());
	return id;
}

int sendRequest(ref ProcessPipes pipes, JSONValue json)
{
	int id;
	json["jsonrpc"] = JSONValue("2.0");
	json["id"] = JSONValue(id = ++idCounter);
	stderr.writeln("--> #", id, " raw");
	pipes.sendPacketRaw(json.toString());
	return id;
}

int sendNotification(ref ProcessPipes pipes, string method, JSONValue params = JSONValue.init)
{
	int id;
	JSONValue json = JSONValue([
		"jsonrpc": JSONValue("2.0"),
		"method": JSONValue(method)
	]);
	if (params != JSONValue.init)
		json["params"] = params;
	stderr.writeln("--> notify method ", method);
	pipes.sendPacketRaw(json.toString());
	return id;
}

int sendNotification(ref ProcessPipes pipes, JSONValue json)
{
	int id;
	json["jsonrpc"] = JSONValue("2.0");
	stderr.writeln("--> notify raw");
	pipes.sendPacketRaw(json.toString());
	return id;
}

void sendPacketRaw(ref ProcessPipes pipes, string json)
{
	pipes.stdin.write("Content-Length: ", json.length, "\r\n");
	pipes.stdin.write("\r\n");
	pipes.stdin.write(json);
	pipes.stdin.flush();
}

JSONValue readPacket(ref ProcessPipes pipes, int expectId = -1)
{
	with (pipes.terminateTimeout())
	{
		int contentLength;
		while (!pipes.stdout.eof)
		{
			auto header = pipes.stdout.readln();
			if (header == "\r\n")
				break;

			if (header.startsWithSI("Content-Length:"))
				contentLength = header["content-length:".length .. $].strip.to!int;
		}

		if (contentLength == 0)
			throw new Exception("Read headers but there was no content length");

		static ubyte[] buffer;
		if (buffer.length < contentLength)
			buffer.length = contentLength;
		auto data = pipes.stdout.rawRead(buffer[0 .. contentLength]);

		if (data.length != contentLength)
			throw new Exception("EOF before packet was fully read");

		auto ret = parseJSON(cast(char[])buffer);
		auto id = "id" in ret;
		if (expectId != -1)
		{
			assert(id);
			assert(id.integer == expectId);
		}
		stderr.writeln("<-- #", id ? id.integer.to!string : "notification");
		return ret;
	}
}
