import std.bitmanip;
import std.bitmanip;
import std.conv;
import std.file;
import std.functional;
import std.json;
import std.path;
import std.process;
import std.stdio;
import std.string;
import std.uuid;

import core.thread;
import core.thread.fiber;

import served.lsp.filereader;
import served.lsp.jsonrpc;
import served.lsp.protocol;
import served.lsp.uri;

version (assert)
{
}
else
	static assert(false, "Compile with asserts.");

__gshared RPCProcessor rpc;
__gshared string cwd;

// https://forum.dlang.org/post/akucvkduasjlwgykkrzs@forum.dlang.org
void copyDir(string inDir, string outDir)
{
	if (!exists(outDir))
		mkdir(outDir);
	else
		if (!isDir(outDir))
			throw new FileException(format("Destination path %s is not a folder.", outDir));

	foreach (entry; dirEntries(inDir.idup, SpanMode.shallow))
	{
		auto fileName = baseName(entry.name);
		auto destName = buildPath(outDir, fileName);
		if (entry.isDir())
			copyDir(entry.name, destName);
		else
			copy(entry.name, destName);
	}
}

void main()
{
	version (Windows)
		string exe = `..\..\serve-d.exe`;
	else
		string exe = `../../serve-d`;

	cwd = buildNormalizedPath(tempDir, randomUUID.toString);
	copyDir("template", cwd);
	writeln("temporary CWD: ", cwd);
	scope (failure)
		writeln("Keeping temporary directory for debugging purposes");
	scope (success)
		rmdirRecurse(cwd);

	auto proc = pipeProcess([exe], Redirect.stdin | Redirect.stdout);

	auto reader = new StdFileReader(proc.stdout);
	reader.start();
	scope (exit)
		reader.stop();
	rpc = new RPCProcessor(reader, proc.stdin);
	auto testMethod = new Fiber(&doTests);
	do
	{
		rpc.call();
		testMethod.call();
		Thread.sleep(1.msecs);
	}
	while (rpc.state != Fiber.State.TERM);
	assert(testMethod.state == Fiber.State.TERM);
	return;
}

void delegate(RequestMessage msg) gotRequest;
void delegate(RequestMessage msg) gotNotify;

shared static this()
{
	gotRequest = toDelegate(&defaultRequestHandler);
	gotNotify = toDelegate(&defaultNotifyHandler);
}

void defaultRequestHandler(RequestMessage msg)
{
	assert(false, "Unexpected request " ~ msg.toJSON.toString);
}

void defaultNotifyHandler(RequestMessage msg)
{
	writeln("Ignoring notification " ~ msg.toJSON.toString);
}

void pumpEvents()
{
	while (rpc.hasData)
	{
		auto msg = rpc.poll;
		if (!msg.id.isNone)
			gotRequest(msg);
		else
			gotNotify(msg);
	}
}

void doTests()
{
	WorkspaceClientCapabilities workspace = {
		configuration: opt(true)
	};
	InitializeParams init = {
		processId: JsonValue(thisProcessID),
		rootUri: uriFromFile(cwd),
		capabilities: {
			workspace: opt(workspace)
		}
	};
	rpc.sendRequest("initialize", init);
	pumpEvents();
	Fiber.yield();
	writeln("done!");
}
