import served.fibermanager;
import served.filereader;
import served.jsonrpc;
import served.protocol;
import served.types : Configuration, uriFromFile, uriToFile;

import painlessjson;

import core.thread;
import core.time;

import std.algorithm;
import std.file;
import std.json;
import std.path;
import std.process;
import std.stdio;
import std.string;
import std.traits;

RPCProcessor rpc;
FiberManager fibers;
Configuration configuration;

string workspacePath;
string sourcePath;

/**
 This test simulates:
 - initialization
 - configuration
 - opening a file
 - auto completing
 - dub.sdl change
 - goto definition
 - diagnostics
 - outline
*/
void runTests()
{
	scope (exit)
	{
		rpc.sendRequest("shutdown", null);
		rpc.notifyMethod("exit");
	}

	string sourceUri = sourcePath.uriFromFile;

	InitializeParams params;
	// serve-d doesn't check the other parameters anyway
	params.capabilities.workspace = WorkspaceClientCapabilities.init.opt;
	params.capabilities.workspace.workspaceFolders = true.opt;
	params.capabilities.workspace.configuration = true.opt;
	params.rootPath = workspacePath;
	params.rootUri = workspacePath.uriFromFile;
	params.processId = thisProcessID;
	params.workspaceFolders = [WorkspaceFolder(params.rootUri, "Workspace 1")];
	InitializeResult result = rpc.sendRequest("initialize", params).result.fromJSON!InitializeResult;
	assert(result.capabilities.workspace.workspaceFolders.supported);
	rpc.notifyMethod("initialized");

	rpc.notifyMethod("workspace/didChangeConfiguration",
			DidChangeConfigurationParams(configuration.toJSON));

	rpc.notifyMethod("textDocument/didOpen",
			DidOpenTextDocumentParams(TextDocumentItem(sourceUri, "d", 1, readText(sourcePath))));

	auto completions = rpc.sendRequest("textDocument/completion", TextDocumentPositionParams(
			TextDocumentIdentifier(sourceUri), Position(7, 2))).result.fromJSON!CompletionList;

	infof("Completion:\n%(%s\n%)", completions.items);

	assert(completions.items.length >= 5);
	assert(completions.items.canFind!(a => a.label == "ubyte"));
	assert(completions.items.canFind!(a => a.label == "ushort"));
	assert(completions.items.canFind!(a => a.label == "uint"));
	assert(completions.items.canFind!(a => a.label == "ulong"));
	assert(completions.items.canFind!(a => a.label == "ungetc"));
}

ResponseMessage processRequest(RequestMessage msg)
{
	ResponseMessage res;
	res.id = msg.id;
	switch (msg.method)
	{
	case "workspace/configuration":
		auto params = msg.params.fromJSON!ConfigurationParams;
		JSONValue[] ret;

		foreach (param; params.items)
		{
			JSONValue item;
			if (param.section.isNull)
				item = configuration.toJSON;
			else
			{
	SectionSwitch:
				switch (param.section)
				{
					static foreach (member; FieldNameTuple!Configuration)
					{
				case member:
						item = __traits(getMember, configuration, member).toJSON;
						break SectionSwitch;
					}
				default:
					item = JSONValue.init;
					break;
				}
			}
			ret ~= item;
		}
		res.result = JSONValue(ret);
		break;
	default:
		res.error = ResponseError(ErrorCode.methodNotFound, "unknown method " ~ msg.method);
		break;
	}
	return res;
}

void processNotify(RequestMessage msg)
{

}

void main(string[] args)
{
	if (args.length > 1 && args[1].startsWith("-"))
	{
		if (args[1] == "--")
			args = args[2 .. $];
		else if (args[1] == "-h" || args[1] == "--help")
		{
			info("Usage: ", args[0], " [options] [--] <serve-d command>");
		}
		else
		{
			info("Unrecognized option ", args[1], ", try --help.");
		}
		return;
	}
	else
		args = args[1 .. $];
	args[0] = buildNormalizedPath(getcwd(), args[0]);

	configuration.d.dcdClientPath = buildPath(getcwd(), "dcd-client");
	configuration.d.dcdServerPath = buildPath(getcwd(), "dcd-server");

	workspacePath = buildPath(getcwd, "workspace");
	sourcePath = buildPath(workspacePath, "source", "app.d");

	infof("Starting %(%s %)", args);
	auto commands = pipe();
	auto served = pipe();
	auto process = spawnProcess(args, commands.readEnd, served.writeEnd,
			File("logs.txt", "w"), null, Config.none, workspacePath);
	scope (exit)
	{
		const ret = process.wait();
		info("serve-d exited with exit code ", ret);
	}

	// infof("Pid is %s. Please attach", process.processID);
	// Thread.sleep(5.seconds);

	auto input = new StdFileReader(served.readEnd);
	input.startReading();
	scope (exit)
		input.stop();
	info("Started file reader");
	rpc = new RPCProcessor(input, commands.writeEnd);
	rpc.call();
	info("Started RPC");

	fibers ~= rpc;
	fibers ~= new Fiber(&runTests);

	while (rpc !is null && rpc.state != Fiber.State.TERM && rpc.running)
	{
		while (rpc.hasData)
		{
			auto msg = rpc.poll;
			if (msg.id.hasData)
				fibers.put(new Fiber(gotRequest(msg)));
			else
				fibers.put(new Fiber(gotNotify(msg)));
		}

		Thread.sleep(10.msecs);
		fibers.call();
	}
	info("Finished.");
}

void delegate() gotRequest(RequestMessage msg)
{
	info("got request ", msg.method);
	return {
		ResponseMessage res;
		try
		{
			res = processRequest(msg);
		}
		catch (Throwable e)
		{
			res.error = ResponseError(e);
			res.error.code = ErrorCode.internalError;
			error("Failed processing request: ", e);
		}
		rpc.send(res);
	};
}

void delegate() gotNotify(RequestMessage msg)
{
	info("got notification ", msg.method);
	return {
		try
		{
			processNotify(msg);
		}
		catch (Throwable e)
		{
			error("Failed processing notification: ", e);
		}
	};
}
