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

	/// Product name to use in error messages
	string productName = "serve-d";

	/// If set to non-zero, call GC.collect every n seconds and GC.minimize
	/// every 5th call. Keeps track of cleaned up memory in trace logs.
	int gcCollectSeconds = 30;
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
///   - `@protocolMethod("shutdown") JsonValue shutdown()`: the method called
///     when the client wants to shutdown the server. Can return anything,
///     recommended return value is `JsonValue(null)`.
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
	import served.lsp.jsonops;
	import served.lsp.jsonrpc;
	import served.lsp.protocol;
	import served.lsp.textdocumentmanager;
	import served.utils.async;
	import served.utils.events;
	import served.utils.fibermanager;

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
	ResponseMessageRaw processRequest(RequestMessageRaw msg)
	{
		debug(PerfTraceLog) mixin(traceStatistics(__FUNCTION__));
		scope (failure)
			error("failure in message ", msg);

		ResponseMessageRaw res;
		if (msg.id.isNone)
			throw new Exception("Called processRequest on a notification");
		res.id = msg.id.deref;
		if (msg.method == "initialize" && !serverInitializeCalled)
		{
			trace("Initializing");
			auto initParams = msg.paramsJson.deserializeJson!InitializeParams;
			auto initResult = ExtensionModule.initialize(initParams);
			eventProcessor.emitExtensionEvent!initializeHook(initParams, initResult);
			res.resultJson = initResult.serializeJson;
			trace("Initialized");
			serverInitializeCalled = true;
			pushFiber({
				Fiber.yield();
				processRequestObservers(msg, initResult);
			});
			return res;
		}

		static if (!is(typeof(ExtensionModule.shutdown)))
		{
			if (msg.method == "shutdown" && !shutdownRequested)
			{
				shutdownRequested = true;
				res.resultJson = `null`;
				return res;
			}
		}

		if (!serverInitializeCalled && msg.method != "shutdown")
		{
			trace("Tried to call command without initializing");
			res.error = ResponseError(ErrorCode.serverNotInitialized);
			return res;
		}

		size_t numHandlers;
		eventProcessor.emitProtocol!(protocolMethod, (name, callSymbol, uda) {
			numHandlers++;
		}, false)(msg.method, msg.paramsJson);

		// trace("Function ", msg.method, " has ", numHandlers, " handlers");
		if (numHandlers == 0)
		{
			io.stderr.writeln(msg);
			res.error = ResponseError(ErrorCode.methodNotFound, "Request method " ~ msg.method ~ " not found");
			return res;
		}

		string workDoneToken, partialResultToken;
		if (msg.paramsJson.looksLikeJsonObject)
		{
			auto v = msg.paramsJson.parseKeySlices!("workDoneToken", "partialResultToken");
			workDoneToken = v.workDoneToken;
			partialResultToken = v.partialResultToken;
		}

		int working = 0;
		string[] partialResults;
		void handlePartialWork(Symbol, Arguments)(Symbol fn, Arguments args)
		{
			working++;
			pushFiber({
				scope (exit)
					working--;
				auto thisId = working;
				trace("Partial ", thisId, " / ", numHandlers, "...");
				auto result = fn(args.expand);
				trace("Partial ", thisId, " = ", result);
				auto json = result.serializeJson;
				if (!partialResultToken.length)
					partialResults ~= json;
				else
					rpc.notifyProgressRaw(partialResultToken, json);
				processRequestObservers(msg, result);
			});
		}

		bool done, found;
		try
		{
			found = eventProcessor.emitProtocolRaw!(protocolMethod, (name, symbol, arguments, uda) {
				if (done)
					return;

				trace("Calling request method ", name);
				alias RequestResultT = typeof(symbol(arguments.expand));

				static if (is(RequestResultT : JsonValue))
				{
					auto requestResult = symbol(arguments.expand);
					res.resultJson = requestResult.serializeJson;
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
					res.resultJson = requestResult.serializeJson;
					done = true;
					processRequestObservers(msg, requestResult);
				}
			}, false)(msg.method, msg.paramsJson);
		}
		catch (MethodException e)
		{
			res.resultJson = null;
			res.error = e.error;
			return res;
		}

		assert(found);

		if (!done)
		{
			while (working > 0)
				Fiber.yield();

			if (!partialResultToken.length)
			{
				size_t reservedLength = 1 + partialResults.length;
				foreach (partial; partialResults)
				{
					assert(partial.looksLikeJsonArray);
					reservedLength += partial.length - 2;
				}
				char[] resJson = new char[reservedLength];
				size_t i = 0;
				resJson.ptr[i++] = '[';
				foreach (partial; partialResults)
				{
					assert(i + partial.length - 2 < resJson.length);
					resJson.ptr[i .. i += (partial.length - 2)] = partial[1 .. $ - 1];
					resJson.ptr[i++] = ',';
				}
				assert(i == resJson.length);
				resJson.ptr[reservedLength - 1] = ']';
				res.resultJson = cast(string)resJson;
			}
			else
			{
				res.resultJson = `[]`;
			}
		}

		return res;
	}

	// calls @postProcotolMethod methods for the given request
	private void processRequestObservers(T)(RequestMessageRaw msg, T result)
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
		}, false)(msg.method, msg.paramsJson, result);
	}

	void processNotify(RequestMessageRaw msg)
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

		if (!serverInitializeCalled)
		{
			trace("Tried to call notification without initializing");
			return;
		}
		documents.process(msg);

		bool gotAny = eventProcessor.emitProtocol!(protocolNotification, (name, callSymbol, uda) {
			trace("Calling notification method ", name);
			try
			{
				callSymbol();
			}
			catch (MethodException e)
			{
				error("Failed notify: ", e);
			}
		}, false)(msg.method, msg.paramsJson);
		if (!gotAny)
			trace("Discarding unknown notification: ", msg);
	}

	void delegate() gotRequest(RequestMessageRaw msg)
	{
		return {
			ResponseMessageRaw res;
			try
			{
				res = processRequest(msg);
			}
			catch (Exception e)
			{
				if (!msg.id.isNone)
					res.id = msg.id.deref;
				auto err = ResponseError(e);
				err.code = ErrorCode.internalError;
				res.error = err;
			}
			catch (Throwable e)
			{
				if (!msg.id.isNone)
					res.id = msg.id.deref;
				auto err = ResponseError(e);
				err.code = ErrorCode.internalError;
				res.error = err;
				rpc.window.showMessage(MessageType.error,
						"A fatal internal error occured in "
						~ serverConfig.productName
						~ " handling this request but it will attempt to keep running: "
						~ e.msg);
			}
			rpc.send(res);
		};
	}

	void delegate() gotNotify(RequestMessageRaw msg)
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
						"A fatal internal error has occured in "
						~ serverConfig.productName
						~ ", but it will attempt to keep running: "
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
		for (int timeout = 10; timeout >= 0 && !input.isRunning; timeout--)
			Thread.sleep(1.msecs);
		trace("Started reading from stdin");

		rpc = new RPCProcessor(input, stdout);
		rpc.call();
		trace("RPC started");
		return runImpl(); 
	}

	/// Same as `run`, assumes `rpc` is initialized and ready
	bool runImpl()
	{
		fibersMutex = new Mutex();

		static if (serverConfig.gcCollectSeconds > 0)
		{
			int gcCollects, totalGcCollects;
			StopWatch gcInterval;
			gcInterval.start();

			void collectGC()
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
				if (!msg.id.isNone)
					pushFiber(gotRequest(msg));
				else
					pushFiber(gotNotify(msg));
			}
			Thread.sleep(10.msecs);
			synchronized (fibersMutex)
				fibers.call();

			static if (serverConfig.gcCollectSeconds > 0)
			{
				if (gcInterval.peek > serverConfig.gcCollectSeconds.seconds)
				{
					collectGC();
				}
			}
		}

		return shutdownRequested;
	}
}

unittest
{
	import core.thread;
	import core.time;

	import std.conv;
	import std.experimental.logger;
	import std.stdio;

	import served.lsp.jsonrpc;
	import served.lsp.protocol;
	import served.utils.events;

	static struct CustomInitializeResult
	{
		bool calledA;
		bool calledB;
		bool calledC;
		bool sanityFalse;
	}

	__gshared static int calledCustomNotify;

	static struct UTServer
	{
	static:
		alias members = __traits(derivedMembers, UTServer);

		CustomInitializeResult initialize(InitializeParams params)
		{
			CustomInitializeResult res;
			res.calledA = true;
			return res;
		}

		@initializeHook
		void myInitHook1(InitializeParams params, ref CustomInitializeResult result)
		{
			assert(result.calledA);
			assert(!result.calledB);
			assert(!result.sanityFalse);

			result.calledB = true;
		}

		@initializeHook
		void myInitHook2(InitializeParams params, ref CustomInitializeResult result)
		{
			assert(result.calledA);
			assert(!result.calledC);
			assert(!result.sanityFalse);

			result.calledC = true;
		}

		@protocolMethod("textDocument/documentColor")
		int myMethod1(DocumentColorParams c)
		{
			return 4 + cast(int)c.textDocument.uri.length;
		}

		static struct NotifyParams
		{
			int i;
		}

		@protocolNotification("custom/notify")
		void myMethod2(NotifyParams params)
		{
			calledCustomNotify = 4 + params.i;
			trace("myMethod2 -> ", calledCustomNotify, " - ptr: ", &calledCustomNotify);
		}
	}

	// we get a bunch of deprecations because of dual-context, but I don't think we can do anything about these.
	mixin LanguageServerRouter!(UTServer) server;

	globalLogLevel = LogLevel.trace;
	sharedLog = new FileLogger(io.stderr);

	MockRPC mockRPC;
	mockRPC.testRPC((rpc) {
		server.rpc = rpc;
		bool started;
		bool exitSuccess;
		auto t = new Thread({
			started = true;
			try
			{
				exitSuccess = server.runImpl();
			}
			catch (Throwable t)
			{
				import std.stdio;

				stderr.writeln("Fatal: mockRPC crashed: ", t);
			}
		});
		t.start();
		do {
			Thread.sleep(10.msecs);
		} while (!started);
		// give it a little more time
		Thread.sleep(200.msecs);

		trace("Started mock RPC");
		mockRPC.writePacket(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file:///","capabilities":{}}}`);
		Thread.sleep(200.msecs);
		assert(server.serverInitializeCalled);
		trace("Initialized");

		auto resObj = ResponseMessageRaw.deserialize(mockRPC.readPacket());
		assert(resObj.error.isNone);

		auto initResult = resObj.resultJson.deserializeJson!CustomInitializeResult;

		assert(initResult.calledA);
		assert(initResult.calledB);
		assert(initResult.calledC);
		assert(!initResult.sanityFalse);
		trace("Initialize OK");

		mockRPC.writePacket(`{"jsonrpc":"2.0","id":1,"method":"textDocument/documentColor","params":{"textDocument":{"uri":"a"}}}`);
		resObj = ResponseMessageRaw.deserialize(mockRPC.readPacket());
		assert(resObj.resultJson == `5`);

		assert(!calledCustomNotify);
		mockRPC.writePacket(`{"jsonrpc":"2.0","method":"custom/notify","params":{"i":4}}`);
		Thread.sleep(200.msecs);
		assert(calledCustomNotify == 8,
			text("calledCustomNotify = ", calledCustomNotify, " - ptr: ", &calledCustomNotify));

		mockRPC.writePacket(`{"jsonrpc":"2.0","id":1,"method":"shutdown","params":{}}`);
		mockRPC.readPacket();
		mockRPC.writePacket(`{"jsonrpc":"2.0","method":"exit","params":{}}`);

		t.join();
		assert(exitSuccess);
	});
}
