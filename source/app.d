import core.thread;
import core.sync.mutex;

import fs = std.file;
import io = std.stdio;
import std.algorithm;
import std.conv;
import std.datetime.stopwatch;
import std.experimental.logger;
import std.functional;
import std.getopt;
import std.json;
import std.path;
import std.string;
import std.traits;

import served.io.http_wrap;
import served.lsp.filereader;
import served.lsp.jsonrpc;
import served.types;
import served.utils.fibermanager;
import served.utils.translate;

import painlessjson;

static import served.extension;

__gshared io.File stdin, stdout;
shared static this()
{
	stdin = io.stdin;
	stdout = io.stdout;
	version (Windows)
		io.stdin = io.File("NUL", "r");
	else version (Posix)
		io.stdin = io.File("/dev/null", "r");
	else
		io.stderr.writeln("warning: no /dev/null implementation on this OS");
	io.stdout = io.stderr;
}

bool initialized = false;

alias Identity(I...) = I;

ResponseMessage processRequest(RequestMessage msg)
{
	ResponseMessage res;
	res.id = msg.id;
	if (msg.method == "initialize" && !initialized)
	{
		trace("Initializing");
		res.result = served.extension.initialize(msg.params.fromJSON!InitializeParams).toJSON;
		trace("Initialized");
		initialized = true;
		return res;
	}
	if (!initialized)
	{
		trace("Tried to call command without initializing");
		res.error = ResponseError(ErrorCode.serverNotInitialized);
		return res;
	}
	foreach (name; served.extension.members)
	{
		static if (__traits(compiles, __traits(getMember, served.extension, name)))
		{
			alias symbol = Identity!(__traits(getMember, served.extension, name));
			static if (symbol.length == 1 && hasUDA!(symbol, protocolMethod))
			{
				static if (isSomeFunction!symbol && __traits(getProtection, symbol[0]) == "public")
				{
					enum method = getUDAs!(symbol, protocolMethod)[0];
					if (msg.method == method.method)
					{
						alias params = Parameters!symbol;
						try
						{
							trace("Calling " ~ name);
							static if (params.length == 0)
								auto requestResult = symbol[0]();
							else static if (params.length == 1)
								auto requestResult = symbol[0](fromJSON!(Parameters!symbol[0])(msg.params));
							else
								static assert(0, "Can't have more than one argument");

							static if (is(typeof(requestResult) : JSONValue))
								res.result = requestResult;
							else
								res.result = toJSON(requestResult);

							processRequestObservers(msg, requestResult);
							return res;
						}
						catch (MethodException e)
						{
							res.error = e.error;
							return res;
						}
					}
				}
			}
		}
	}

	io.stderr.writeln(msg);
	res.error = ResponseError(ErrorCode.methodNotFound);
	return res;
}

void processRequestObservers(T)(RequestMessage msg, T result)
{
	foreach (name; served.extension.members)
	{
		static if (__traits(compiles, __traits(getMember, served.extension, name)))
		{
			alias symbol = Identity!(__traits(getMember, served.extension, name));
			static if (symbol.length == 1 && hasUDA!(symbol, postProtocolMethod))
			{
				static if (isSomeFunction!symbol && __traits(getProtection, symbol[0]) == "public")
				{
					enum method = getUDAs!(symbol, protocolMethod)[0];
					if (msg.method == method.method)
					{
						alias params = Parameters!symbol;
						try
						{
							trace("Calling post " ~ name);
							static if (params.length == 0)
								symbol[0]();
							else static if (params.length == 1)
								symbol[0](fromJSON!(Parameters!symbol[0])(msg.params));
							else static if (params.length == 2)
								symbol[0](fromJSON!(Parameters!symbol[0])(msg.params), result);
							else
								static assert(0, "Can't have more than one argument");
						}
						catch (MethodException e)
						{
							error("Error in post-protocolMethod: ", e);
						}
					}
				}
			}
		}
	}
}

void processNotify(RequestMessage msg)
{
	// even though the spec says the process should not stop before exit, vscode-languageserver doesn't call exit after shutdown so we just shutdown on the next request.
	// this also makes sure we don't operate on invalid states and segfault.
	if (msg.method == "exit" || served.extension.shutdownRequested)
	{
		rpc.stop();
		if (!served.extension.shutdownRequested)
			served.extension.shutdown();
		return;
	}
	if (!initialized)
	{
		trace("Tried to call notification without initializing");
		return;
	}
	if (msg.method == "workspace/didChangeConfiguration")
		served.extension.processConfigChange(msg.params["settings"].parseConfiguration);
	documents.process(msg);
	foreach (name; served.extension.members)
	{
		static if (__traits(compiles, __traits(getMember, served.extension, name)))
		{
			alias symbol = Identity!(__traits(getMember, served.extension, name));
			static if (symbol.length == 1 && hasUDA!(symbol, protocolNotification))
			{
				static if (isSomeFunction!symbol && __traits(getProtection, symbol[0]) == "public")
				{
					enum method = getUDAs!(symbol, protocolNotification)[0];
					if (msg.method == method.method)
					{
						alias params = Parameters!symbol;
						try
						{
							static if (params.length == 0)
								symbol[0]();
							else static if (params.length == 1)
								symbol[0](fromJSON!(Parameters!symbol[0])(msg.params));
							else
								static assert(0, "Can't have more than one argument");
						}
						catch (MethodException e)
						{
							error("Failed notify: ", e);
						}
					}
				}
			}
		}
	}
}

void printVersion(io.File output = io.stdout)
{
	import Compiler = std.compiler;
	import OS = std.system;

	static if (__traits(compiles, {
			import workspaced.info : BundledDependencies, WorkspacedVersion = Version;
		}))
		import workspaced.info : BundledDependencies, WorkspacedVersion = Version;
	else
		import source.workspaced.info : BundledDependencies, WorkspacedVersion = Version;
	import source.served.info;

	output.writefln("serve-d v%(%s.%)%s with workspace-d v%(%s.%)", Version,
			VersionSuffix.length ? text('-', VersionSuffix) : VersionSuffix, WorkspacedVersion);
	output.writefln("Included features: %(%s, %)", IncludedFeatures);
	// There will always be a line which starts with `Built: ` forever, it is considered stable. If there is no line, assume version 0.1.2
	output.writefln("Built: %s", __TIMESTAMP__);
	output.writeln("with compiler ", Compiler.name, " v",
			Compiler.version_major.to!string, ".", Compiler.version_minor.to!string,
			" on ", OS.os.to!string, " ", OS.endian.to!string);
	output.writefln(BundledDependencies);
}

private string[] findDuplicates(string[] fields)
{
	string[] dups;
	foreach (i, field; fields)
	{
		if (field == "object" || field == "served" || field == "std" || field == "io"
				|| field == "workspaced" || field == "fs")
			continue;

		if (fields[0 .. i].canFind(field) || fields[i + 1 .. $].canFind(field))
			dups ~= field;
	}
	return dups;
}

enum duplicates = findDuplicates([served.extension.members]);
static if (duplicates.length > 0)
{
	pragma(msg, "duplicates: ", duplicates);
	static assert(false, "Found duplicate method handlers of same name");
}

__gshared FiberManager fibers;
int main(string[] args)
{
	debug globalLogLevel = LogLevel.trace;

	bool printVer;
	string[] features;
	string[] provides;
	string lang = "en";
	bool wait;
	//dfmt off
	auto argInfo = args.getopt(
		"r|require", "Adds a feature set that is required. Unknown feature sets will intentionally crash on startup", &features,
		"p|provide", "Features to let the editor handle for better integration", &provides,
		"v|version", "Print version of program", &printVer,
		"lang", "Change the language of GUI messages", &lang,
		"wait", "Wait for a second before starting (for debugging)", &wait);
	//dfmt on
	if (wait)
		Thread.sleep(2.seconds);
	if (argInfo.helpWanted)
	{
		if (printVer)
			printVersion();
		defaultGetoptPrinter("workspace-d / vscode-language-server bridge", argInfo.options);
		return 0;
	}
	if (printVer)
	{
		printVersion();
		return 0;
	}

	if (lang.length >= 2) // ja-JP -> ja, en-GB -> en, etc
		currentLanguage = lang[0 .. 2];
	if (currentLanguage != "en")
		info("Setting language to ", currentLanguage);

	fibersMutex = new Mutex();

	foreach (feature; features)
		if (!IncludedFeatures.canFind(feature.toLower.strip))
		{
			io.stderr.writeln();
			io.stderr.writeln(
					"FATAL: Extension-requested feature set '" ~ feature
					~ "' is not in this version of serve-d!");
			io.stderr.writeln("---");
			io.stderr.writeln("HINT: Maybe serve-d is outdated?");
			io.stderr.writeln();
			return 1;
		}
	trace("Features fulfilled");

	foreach (provide; provides)
	{
		// don't forget to update README.md if adding stuff!
		switch (provide)
		{
		case "http":
			letEditorDownload = true;
			trace("Interactive HTTP downloads handled via editor");
			break;
		case "implement-snippets":
			import served.commands.code_actions : implementInterfaceSnippets;

			implementInterfaceSnippets = true;
			trace("Auto-implement interface supports snippets");
			break;
		case "context-snippets":
			import served.commands.complete : doCompleteSnippets;

			doCompleteSnippets = true;
			trace("Context snippets handled by serve-d");
			break;
		default:
			warningf("Unknown --provide flag '%s' provided. Maybe serve-d is outdated?", provide);
			break;
		}
	}

	version (Windows)
		auto input = new WindowsStdinReader();
	else version (Posix)
		auto input = new PosixStdinReader();
	else
		auto input = new StdFileReader(stdin);
	input.start();
	scope (exit)
		input.stop();
	trace("Started reading from stdin");

	rpc = new RPCProcessor(input, stdout);
	rpc.call();
	trace("RPC started");

	int gcCollects;
	StopWatch gcInterval;
	gcInterval.start();

	fibers ~= rpc;

	served.extension.spawnFiberImpl = (&pushFiber!(void delegate())).toDelegate;
	pushFiber(&served.extension.parallelMain);

	printVersion(io.stderr);

	while (rpc.state != Fiber.State.TERM)
	{
		while (rpc.hasData)
		{
			auto msg = rpc.poll;
			// Log on client side instead! (vscode setting: "serve-d.trace.server": "verbose")
			//trace("Message: ", msg);
			if (msg.id.hasData)
				pushFiber(gotRequest(msg));
			else
				pushFiber(gotNotify(msg));
		}
		Thread.sleep(10.msecs);
		synchronized (fibersMutex)
			fibers.call();

		if (gcInterval.peek > 30.seconds)
		{
			import core.memory : GC;

			auto before = GC.stats();
			StopWatch gcSpeed;
			gcSpeed.start();

			GC.collect();

			gcCollects++;
			if (gcCollects > 5)
			{
				GC.minimize();
				gcCollects = 0;
			}

			gcSpeed.stop();
			auto after = GC.stats();

			if (before != after)
				tracef("GC run in %s. Freed %s bytes (%s bytes allocated, %s bytes available)", gcSpeed.peek,
						cast(long) before.usedSize - cast(long) after.usedSize, after.usedSize, after.freeSize);
			else
				trace("GC run in ", gcSpeed.peek);

			gcInterval.reset();
		}
	}

	return served.extension.shutdownRequested ? 0 : 1;
}

void delegate() gotRequest(RequestMessage msg)
{
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

__gshared Mutex fibersMutex;
void pushFiber(T)(T callback, int pages = 20, string file = __FILE__, int line = __LINE__)
{
	synchronized (fibersMutex)
		fibers.put(new Fiber(callback, 4096 * pages), file, line);
}
