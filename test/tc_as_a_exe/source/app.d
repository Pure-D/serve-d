import std.bitmanip;
import std.conv;
import std.experimental.logger;
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
import served.lsp.jsonops;
import served.lsp.jsonrpc;
import served.lsp.protocol;
import served.lsp.uri;

version (assert)
{
}
else
	static assert(false, "Compile with asserts.");

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

	globalLogLevel = LogLevel.all;

	cwd = buildNormalizedPath(tempDir, randomUUID.toString);
	copyDir("template", cwd);
	info("temporary CWD: ", cwd);
	scope (failure)
		info("Keeping temporary directory for debugging purposes");
	scope (success)
		rmdirRecurse(cwd);

	auto proc = pipeProcess([exe, "--loglevel=all"], Redirect.stdin | Redirect.stdout);

	auto reader = newFileReader(proc.stdout);
	reader.start();
	scope (exit)
		reader.stop();
	rpc = new RPCProcessor(reader, proc.stdin);
	auto testMethod = new Fiber(&doTests);
	do
	{
		rpc.call();
		if (testMethod.state == Fiber.State.TERM) {
			if (rpc.state == Fiber.State.TERM)
				break;
			assert(false, "doTests exitted too early ");
		}
		testMethod.call();
		Thread.sleep(1.msecs);
	}
	while (rpc.state != Fiber.State.TERM);
	assert(testMethod.state == Fiber.State.TERM);
	auto exitCode = proc.pid.wait;
	assert(exitCode == 0, "serve-d failed with exit code " ~ exitCode.to!string);
	return;
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
	InitializeParams init = InitializeParams(
		processId: typeof(InitializeParams.processId)(thisProcessID),
		rootUri: uriFromFile(cwd),
		capabilities: ClientCapabilities(
			workspace: opt(workspace)
		)
	);
	auto msg = rpc.sendRequest("initialize", init, 10.seconds);
	info("Response: ", msg.resultJson);

	// TODO: do actual tests here

	info("Shutting down...");
	rpc.sendRequest("shutdown", init);
	pumpEvents();
	Fiber.yield();
	rpc.notifyMethod("exit");
	pumpEvents();
	Thread.sleep(2.seconds); // give serve-d a chance to clean up
	Fiber.yield();
}
