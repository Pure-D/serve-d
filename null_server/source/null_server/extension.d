module null_server.extension;

import served.lsp.protocol;
import served.utils.events;

import core.thread;

alias members = __traits(derivedMembers, null_server.extension);

InitializeResult initialize(InitializeParams params)
{
	ServerCapabilities ret;
	ret.experimental = JsonValue("initialized null server");
	return InitializeResult(ret);
}

@protocolMethod("dummy/testString")
string testString(string param)
{
	return param ~ "_ok";
}

struct TestParams
{
	string name;
	int num;
	string[] arr;
}

struct TestResult
{
	string ret;
	int a;
	string[] x;
}

@protocolMethod("dummy/testStruct")
TestResult testStruct(TestParams param)
{
	TestResult result;
	result.ret = param.name ~ "_ok";
	result.a = param.num + 1;
	result.x = param.arr;
	return result;
}

@protocolMethod("dummy/testJson")
JsonValue testJson(JsonValue param)
{
	return JsonValue([
		"orig": param,
		"extra": JsonValue("hello")
	]);
}

@protocolMethod("dummy/testVoid")
int testVoid()
{
	return 4;
}

@protocolNotification("dummy/testNotify")
void testNotify()
{
	import app : rpc;
	import std.stdio;

	stderr.writeln("got notify");
	rpc.notifyMethod("dummy/replyNotify");
}

@protocolMethod("dummy/testPartial")
int[] testPartial1()
{
	Fiber.yield();
	return [1, 2];
}

@protocolMethod("dummy/testPartial")
int[] testPartial2()
{
	foreach (i; 0 .. 10)
		Fiber.yield();
	return [3, 4];
}

@protocolMethod("dummy/testPartial")
int[] testPartial3()
{
	foreach (i; 0 .. 100)
		Fiber.yield();
	return [5, 6];
}
