/// Base APIs to create LSP servers quickly. Reconfigures stdin and stdout upon
/// importing to avoid accidental usage of the RPC channel. Changes stdin to a
/// null file and stdout to stderr.
module served.serverbase;

import served.utils.events : EventProcessorConfig;

import io = std.stdio;

/// Actual stdin/stdio as used for RPC communication.
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

struct LanguageServerConfig
{
	int defaultPages = 20;
	int fiberPageSize = 4096;

	EventProcessorConfig eventConfig;
}

// dumps a performance/GC trace log to served_trace.log
//debug = PerfTraceLog;

/// Utility to setup an RPC connection via stdin/stdout and route all requests
/// to methods defined in the given extension module.
///
/// Params:
///   ExtensionModule = a module defining the following members:
///   - `members`: a compile time list of all members in all modules that should
///     be introspected to be called automatically on matching RPC commands.
///   - `InitializeResult initialize(InitializeParams)`: initialization method.
///
///   Optional:
///   - `bool shutdownRequested`: a boolean that is set to true before the
///     `shutdown` method handler or earlier which will terminate the RPC loop
///     gracefully and wait for an `exit` notification to actually exit.
///   - `@protocolMethod("shutdown") JSONValue shutdown()`: the method called
///     when the client wants to shutdown the server. Can return anything,
///     recommended return value is `JSONValue(null)`.
///   - `parallelMain`: an optional method which is run alongside everything
///     else in parallel using fibers. Should yield as much as possible when
///     there is nothing to do.
mixin template LanguageServerRouter(alias ExtensionModule, LanguageServerConfig serverConfig = LanguageServerConfig.init)
{
	static assert(is(typeof(ExtensionModule.members)), "Missing members field in ExtensionModule " ~ ExtensionModule.stringof);
	static assert(is(typeof(ExtensionModule.initialize)), "Missing initialize function in ExtensionModule " ~ ExtensionModule.stringof);

	import core.sync.mutex;
	import core.thread;

	import served.lsp.filereader;
	import served.lsp.jsonrpc;
	import served.lsp.protocol;
	import served.lsp.textdocumentmanager;
	import served.utils.async;
	import served.utils.events;
	import served.utils.fibermanager;

	import painlessjson;

	import std.datetime.stopwatch;
	import std.experimental.logger;
	import std.functional;
	import std.json;

	import io = std.stdio;

	alias members = ExtensionModule.members;

	static if (is(typeof(ExtensionModule.shutdownRequested)))
		alias shutdownRequested = ExtensionModule.shutdownRequested;
	else
		bool shutdownRequested;

	__gshared bool serverInitializeCalled = false;

	mixin EventProcessor!(ExtensionModule, serverConfig.eventConfig) eventProcessor;

	/// Calls a method associated with the given request type in the 
	ResponseMessage processRequest(RequestMessage msg)
	{
		debug(PerfTraceLog) mixin(traceStatistics(__FUNCTION__));

		ResponseMessage res;
		res.id = msg.id;
		if (msg.method == "initialize" && !serverInitializeCalled)
		{
			trace("Initializing");
			res.result = ExtensionModule.initialize(msg.params.fromJSON!InitializeParams).toJSON;
			trace("Initialized");
			serverInitializeCalled = true;
			return res;
		}
		if (!serverInitializeCalled)
		{
			trace("Tried to call command without initializing");
			res.error = ResponseError(ErrorCode.serverNotInitialized);
			return res;
		}

		size_t numHandlers;
		eventProcessor.emitProtocol!(protocolMethod, (name, callSymbol, uda) {
			numHandlers++;
		}, false)(msg.method, msg.params);

		// trace("Function ", msg.method, " has ", numHandlers, " handlers");
		if (numHandlers == 0)
		{
			io.stderr.writeln(msg);
			res.error = ResponseError(ErrorCode.methodNotFound);
			return res;
		}

		JSONValue workDoneToken, partialResultToken;
		if (msg.params.type == JSONType.object)
		{
			if (auto doneToken = "workDoneToken" in msg.params)
				workDoneToken = *doneToken;
			if (auto partialToken = "partialResultToken" in msg.params)
				partialResultToken = *partialToken;
		}

		int working = 0;
		JSONValue[] partialResults;
		void handlePartialWork(Symbol, Arguments)(Symbol fn, Arguments args)
		{
			import painlessjson : toJSON;

			working++;
			pushFiber({
				scope (exit)
					working--;
				auto thisId = working;
				trace("Partial ", thisId, " / ", numHandlers, "...");
				auto result = fn(args.expand);
				trace("Partial ", thisId, " = ", result);
				JSONValue json = toJSON(result);
				if (partialResultToken == JSONValue.init)
					partialResults ~= json;
				else
					rpc.notifyMethod("$/progress", JSONValue([
						"token": partialResultToken,
						"value": json
					]));
				processRequestObservers(msg, json);
			});
		}

		bool done;
		bool found = eventProcessor.emitProtocolRaw!(protocolMethod, (name, symbol, arguments, uda) {
			if (done)
				return;

			try
			{
				trace("Calling ", name);
				alias RequestResultT = typeof(symbol(arguments.expand));

				static if (is(RequestResultT : JSONValue))
				{
					auto requestResult = symbol(arguments.expand);
					res.result = requestResult;
					done = true;
					processRequestObservers(msg, requestResult);
				}
				else
				{
					static if (is(RequestResultT : T[], T))
					{
						if (numHandlers > 1)
						{
							handlePartialWork(symbol, arguments);
							return;
						}
					}
					else assert(numHandlers == 1, "Registered more than one "
						~ msg.method ~ " handler on non-partial method returning "
						~ RequestResultT.stringof);
					auto requestResult = symbol(arguments.expand);
					res.result = toJSON(requestResult);
					done = true;
					processRequestObservers(msg, requestResult);
				}
			}
			catch (MethodException e)
			{
				res.error = e.error;
			}
		}, false)(msg.method, msg.params);

		assert(found);

		if (!done)
		{
			while (working > 0)
				Fiber.yield();

			if (partialResultToken == JSONValue.init)
			{
				JSONValue[] combined;
				foreach (partial; partialResults)
				{
					assert(partial.type == JSONType.array);
					combined ~= partial.array;
				}
				res.result = JSONValue(combined);
			}
		}

		return res;
	}

	// calls @postProcotolMethod methods for the given request
	private void processRequestObservers(T)(RequestMessage msg, T result)
	{
		eventProcessor.emitProtocol!(postProtocolMethod, (name, callSymbol, uda) {
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
		if (msg.method == "exit" || shutdownRequested)
		{
			rpc.stop();
			if (!shutdownRequested)
			{
				shutdownRequested = true;
				static if (is(typeof(ExtensionModule.shutdown)))
					ExtensionModule.shutdown();
			}
			return;
		}

		static if (!is(typeof(ExtensionModule.shutdown)))
		{
			if (msg.method == "shutdown" && !shutdownRequested)
			{
				shutdownRequested = true;
				return;
			}
		}

		if (!serverInitializeCalled)
		{
			trace("Tried to call notification without initializing");
			return;
		}
		documents.process(msg);

		eventProcessor.emitProtocol!(protocolNotification, (name, callSymbol, uda) {
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

	__gshared FiberManager fibers;
	__gshared Mutex fibersMutex;

	void pushFiber(T)(T callback, int pages = serverConfig.defaultPages, string file = __FILE__, int line = __LINE__)
	{
		synchronized (fibersMutex)
			fibers.put(new Fiber(callback, serverConfig.fiberPageSize * pages), file, line);
	}

	RPCProcessor rpc;
	TextDocumentManager documents;

	/// Runs the language server and returns true once it exited gracefully or
	/// false if it didn't exit gracefully.
	bool run()
	{
		auto input = newStdinReader();
		input.start();
		scope (exit)
			input.stop();
		trace("Started reading from stdin");

		fibersMutex = new Mutex();

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

		spawnFiberImpl = (&pushFiber!(void delegate())).toDelegate;

		static if (is(typeof(ExtensionModule.parallelMain)))
			pushFiber(&ExtensionModule.parallelMain);

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

		return shutdownRequested;
	}
}