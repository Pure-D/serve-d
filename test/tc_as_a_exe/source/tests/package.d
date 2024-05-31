module tests;

public import core.thread : Fiber, Thread;
public import core.time;
public import served.lsp.jsonrpc;
public import served.lsp.protocol;
public import served.lsp.uri;
public import std.conv;
public import std.experimental.logger;
public import std.path;
public import std.process : thisProcessID;
import std.functional : toDelegate;

abstract class ServedTest
{
	this(string servedExe)
	{
		gotRequest = toDelegate(&defaultRequestHandler);
		gotNotify = toDelegate(&defaultNotifyHandler);
		this.servedExe = servedExe;
	}

	abstract void run();

	void tick()
	{
		pumpEvents();
		Fiber.yield();
	}

	void processResponse(void delegate(RequestMessageRaw msg) cb)
	{
		bool called;
		gotRequest = (msg) { called = true; cb(msg); };
		tick();
		assert(called, "no response received!");
		gotRequest = null;
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

	protected string servedExe;

	RPCProcessor rpc;

	void delegate(RequestMessageRaw msg) gotRequest;
	void delegate(RequestMessageRaw msg) gotNotify;
}

void defaultRequestHandler(RequestMessageRaw msg)
{
	assert(false, "Unexpected request " ~ msg.toString);
}

void defaultNotifyHandler(RequestMessageRaw msg)
{
	info("Ignoring notification " ~ msg.toString);
}

abstract class ServedInstancedTest : ServedTest
{
	import std.file;
	import std.process;

	string templateDir;
	string cwd;

	this(string servedExe, string templateDir)
	{
		super(servedExe);
		this.templateDir = templateDir;
	}

	override void run()
	{
		import served.lsp.filereader;
		import std.uuid;

		cwd = buildNormalizedPath(tempDir, randomUUID.toString);
		copyDir("template", cwd);
		info("temporary CWD: ", cwd);
		scope (failure)
			info("Keeping temporary directory for debugging purposes");
		scope (success)
			rmdirRecurse(cwd);

		auto proc = pipeProcess([servedExe, "--loglevel=all"], Redirect.stdin |
				Redirect.stdout);

		auto reader = newFileReader(proc.stdout);
		reader.start();
		scope (exit)
			reader.stop();
		rpc = new RPCProcessor(reader, proc.stdin);
		auto testMethod = new Fiber(&runImpl);
		do
		{
			rpc.call();
			if (testMethod.state == Fiber.State.TERM)
			{
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
	}

	abstract void runImpl();
}

// https://forum.dlang.org/post/akucvkduasjlwgykkrzs@forum.dlang.org
void copyDir(string inDir, string outDir)
{
	import std.file;
	import std.format;

	if (!exists(outDir))
		mkdir(outDir);
	else if (!isDir(outDir))
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
