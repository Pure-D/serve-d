/**
 * Entry-point to serve-d
 *
 * Replaces std.stdio stdout with stderr so writeln calls don't accidentally
 * write to the RPC output.
 *
 * Handles all command line arguments, possibly modifying global state variables
 * when enabling serve-d specific protocol extensions are requested.
 *
 * Handles all the request/notification dispatch, calls (de)serialization of
 * given JSON parameters and return values and responds back to the RPC.
 *
 * Performs periodic GC cleanup and invokes the fiber scheduler, pushing
 * incoming RPC requests as tasks to the fiber scheduler.
 */
module app;

// dumps a performance/GC trace log to served_trace.log
//debug = PerfTraceLog;

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
import served.utils.trace;
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

ResponseMessage processRequest(RequestMessage msg)
{
	debug(PerfTraceLog) mixin(traceStatistics(__FUNCTION__));

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

	bool found = emitProtocol!(protocolMethod, (name, callSymbol, uda) {
		try
		{
			trace("Calling " ~ name);
			auto requestResult = callSymbol();

			static if (is(typeof(requestResult) : JSONValue))
				res.result = requestResult;
			else
				res.result = toJSON(requestResult);

			processRequestObservers(msg, requestResult);
		}
		catch (MethodException e)
		{
			res.error = e.error;
		}
	}, true)(msg.method, msg.params);

	if (!found)
	{
		io.stderr.writeln(msg);
		res.error = ResponseError(ErrorCode.methodNotFound);
	}

	return res;
}

void processRequestObservers(T)(RequestMessage msg, T result)
{
	emitProtocol!(postProtocolMethod, (name, callSymbol, uda) {
		try
		{
			callSymbol();
		}
		catch (MethodException e)
		{
			error("Error in post-protocolMethod: ", e);
		}
	}, false)(msg.method, msg.params, result);
}

void processNotify(RequestMessage msg)
{
	debug(PerfTraceLog) mixin(traceStatistics(__FUNCTION__));

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

	emitProtocol!(protocolNotification, (name, callSymbol, uda) {
		try
		{
			callSymbol();
		}
		catch (MethodException e)
		{
			error("Failed notify: ", e);
		}
	}, false)(msg.method, msg.params);
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

	int gcCollects, totalGcCollects;
	StopWatch gcInterval;
	gcInterval.start();

	scope (exit)
	{
		debug(PerfTraceLog)
		{
			import core.memory : GC;
			import std.stdio : File;

			auto traceLog = File("served_trace.log", "w");

			auto totalAllocated = GC.stats().allocatedInCurrentThread;
			auto profileStats = GC.profileStats();

			traceLog.writeln("manually collected GC ", totalGcCollects, " times");
			traceLog.writeln("total ", profileStats.numCollections, " collections");
			traceLog.writeln("total collection time: ", profileStats.totalCollectionTime);
			traceLog.writeln("total pause time: ", profileStats.totalPauseTime);
			traceLog.writeln("max collection time: ", profileStats.maxCollectionTime);
			traceLog.writeln("max pause time: ", profileStats.maxPauseTime);
			traceLog.writeln("total allocated in main thread: ", totalAllocated);
			traceLog.writeln();

			dumpTraceInfos(traceLog);
		}
	}

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
			totalGcCollects++;
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
		catch (Exception e)
		{
			res.id = msg.id;
			res.error = ResponseError(e);
			res.error.code = ErrorCode.internalError;
		}
		catch (Throwable e)
		{
			res.id = msg.id;
			res.error = ResponseError(e);
			res.error.code = ErrorCode.internalError;
			rpc.window.showMessage(MessageType.error,
					"A fatal internal error occured in serve-d handling this request but it will attempt to keep running: "
					~ e.msg);
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
		catch (Exception e)
		{
			error("Failed processing notification: ", e);
		}
		catch (Throwable e)
		{
			error("Attempting to recover from fatal issue: ", e);
			rpc.window.showMessage(MessageType.error,
					"A fatal internal error has occured in serve-d, but it will attempt to keep running: "
					~ e.msg);
		}
	};
}

__gshared Mutex fibersMutex;
void pushFiber(T)(T callback, int pages = 20, string file = __FILE__, int line = __LINE__)
{
	synchronized (fibersMutex)
		fibers.put(new Fiber(callback, 4096 * pages), file, line);
}
