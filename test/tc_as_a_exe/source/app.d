import std.bitmanip;
import std.conv;
import std.file;
import std.process;
import std.string;
import std.stdio;
import std.json;

version (assert)
{
}
else
	static assert(false, "Compile with asserts.");

void main()
{
	writeln("TODO: LSP client test");
	return;
}

void main2()
{
	string dir = getcwd;
	JSONValue response;

	//scope backend = new WorkspaceD();
	version (Windows)
		auto backend = pipeProcess(["..\\..\\workspace-d.exe"], Redirect.stdout | Redirect.stdin);
	else
		auto backend = pipeProcess(["../../workspace-d"], Redirect.stdout | Redirect.stdin);

	//auto instance = backend.addInstance(dir);
	backend.stdin.writeRequest(10, `{"cmd": "new", "cwd": ` ~ JSONValue(dir).toString ~ `}`);
	assert(backend.stdout.readResponse(10).type == JSONType.true_);

	//backend.register!FSWorkspaceComponent;
	backend.stdin.writeRequest(20,
			`{"cmd": "load", "component": "fsworkspace", "cwd": ` ~ JSONValue(dir).toString ~ `}`);
	assert(backend.stdout.readResponse(20).type == JSONType.true_);

	//backend.register!DscannerComponent;
	backend.stdin.writeRequest(21,
			`{"cmd": "load", "component": "dscanner", "cwd": ` ~ JSONValue(dir).toString ~ `}`);
	assert(backend.stdout.readResponse(21).type == JSONType.true_);

	//auto fsworkspace = backend.get!FSWorkspaceComponent(dir);
	//assert(instance.importPaths == [getcwd]);
	backend.stdin.writeRequest(30, `{"cmd": "import-paths", "cwd": ` ~ JSONValue(dir).toString ~ `}`);
	response = backend.stdout.readResponse(30);
	assert(response.type == JSONType.array);
	assert(response.array.length == 1);
	assert(response.array[0].type == JSONType.string);
	assert(response.array[0].str == getcwd);

	//fsworkspace.addImports(["source"]);
	backend.stdin.writeRequest(40,
			`{"cmd": "call", "component": "fsworkspace", "method": "addImports", "params": [["source"]], "cwd": ` ~ JSONValue(
				dir).toString ~ `}`);
	backend.stdout.readResponse(40);

	//dscanner.resolveRanges(code, ref issues);
	backend.stdin.writeRequest(41,
			`{"cmd": "call", "component": "dscanner", "method": "resolveRanges", "params": ["cool code", [{"file": "something.d", "line": 1, "column": 4, "type": "custom.type", "description": "custom description", "key": "custom.key"}]], "cwd": ` ~ JSONValue(
				dir).toString ~ `}`);
	response = backend.stdout.readResponse(41);
	assert(response.type == JSONType.array);
	assert(response.array.length == 1);
	assert(response.array[0].type == JSONType.object);
	assert(response.array[0].object["file"].str == "something.d");
	assert(response.array[0].object["line"].integer == 1);
	assert(response.array[0].object["column"].integer == 4);
	assert(response.array[0].object["type"].str == "custom.type");
	assert(response.array[0].object["description"].str == "custom description");
	assert(response.array[0].object["key"].str == "custom.key");
	assert(response.array[0].object["range"].type == JSONType.array);

	//assert(instance.importPaths == [getcwd, "source"]);
	backend.stdin.writeRequest(50, `{"cmd": "import-paths", "cwd": ` ~ JSONValue(dir).toString ~ `}`);
	response = backend.stdout.readResponse(50);
	assert(response.type == JSONType.array);
	assert(response.array.length == 2);
	assert(response.array[0].type == JSONType.string);
	assert(response.array[0].str == getcwd);
	assert(response.array[1].type == JSONType.string);
	assert(response.array[1].str == "source");
}

void writeRequest(File stdin, int id, JSONValue data)
{
	stdin.writeRequest(id, data.toString);
}

void writeRequest(File stdin, int id, string data)
{
	stdin.rawWrite((cast(uint) data.length + 4).nativeToBigEndian);
	stdin.rawWrite(id.nativeToBigEndian);
	stdin.rawWrite(data);
	stdin.flush();
	writefln("%s >> %s", id, data);
}

JSONValue readResponse(File stdout, int expectedId = 0x7F000001)
{
	import std.algorithm;

	ubyte[512] skipBuf;
	ubyte[4] intBuf;
	uint length;
	int reqId;
	while (true)
	{
		stdout.rawRead(intBuf[]);
		length = intBuf.bigEndianToNative!uint;
		stdout.rawRead(intBuf[]);
		reqId = intBuf.bigEndianToNative!uint;
		if (expectedId != 0x7F000001 && expectedId != reqId)
		{
			writefln("%s << <skipped %d bytes>", reqId, length);
			if (length > 4)
			{
				length -= 4;
				while (length > 0)
					length -= stdout.rawRead(skipBuf[0 .. min($, length)]).length;
			}
		}
		else
			break;
	}

	if (length > 4)
	{
		ubyte[] data = new ubyte[length - 4];
		stdout.rawRead(data);
		writefln("%s << %s", reqId, cast(char[]) data);
		return parseJSON(cast(char[]) data);
	}
	else
	{
		writefln("%s << <empty>", reqId);
		return JSONValue.init;
	}
}
