import core.thread;
import core.sync.mutex;

import io = std.stdio;
import fs = std.file;
import std.getopt;
import std.functional;
import std.algorithm;
import std.string;
import std.json;
import std.path;
import std.conv;
import std.traits;
import std.experimental.logger;

import served.fibermanager;
import served.filereader;
import served.jsonrpc;
import served.types;
import served.translate;

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

import painlessjson;

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
	foreach (name; __traits(derivedMembers, served.extension))
	{
		static if (__traits(compiles, __traits(getMember, served.extension, name)))
		{
			alias symbol = Identity!(__traits(getMember, served.extension, name));
			static if (isSomeFunction!symbol && __traits(getProtection, symbol[0]) == "public")
			{
				static if (hasUDA!(symbol, protocolMethod))
				{
					enum method = getUDAs!(symbol, protocolMethod)[0];
					if (msg.method == method.method)
					{
						alias params = Parameters!symbol;
						try
						{
							trace("Calling " ~ name);
							static if (params.length == 0)
								res.result = symbol[0]().toJSON;
							else static if (params.length == 1)
								res.result = symbol[0](fromJSON!(Parameters!symbol[0])(msg.params)).toJSON;
							else
								static assert(0, "Can't have more than one argument");
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
		served.extension.processConfigChange(msg.params["settings"].fromJSON!Configuration);
	documents.process(msg);
	foreach (name; __traits(derivedMembers, served.extension))
	{
		static if (__traits(compiles, __traits(getMember, served.extension, name)))
		{
			alias symbol = Identity!(__traits(getMember, served.extension, name));
			static if (isSomeFunction!symbol && __traits(getProtection, symbol[0]) == "public")
			{
				static if (hasUDA!(symbol, protocolNotification))
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

void printVersion()
{
	static if (__traits(compiles, {
			import workspaced.info : WorkspacedVersion = Version;
		}))
		import workspaced.info : WorkspacedVersion = Version;
	else
		import source.workspaced.info : WorkspacedVersion = Version;
	import source.served.info;

	io.writefln("serve-d v%(%s.%) with workspace-d v%(%s.%)", Version, WorkspacedVersion);
	io.writefln("Included features: %(%s, %)", IncludedFeatures);
	// There will always be a line which starts with `Built: ` forever, it is considered stable. If there is no line, assume version 0.1.2
	io.writefln("Built: %s", __TIMESTAMP__);
}

__gshared FiberManager fibers;
int main(string[] args)
{
	debug globalLogLevel = LogLevel.trace;

	bool printVer;
	string[] features;
	string lang = "en";
	bool wait;
	//dfmt off
	auto argInfo = args.getopt(
		"r|require", "Adds a feature set that is required. Unknown feature sets will intentionally crash on startup", &features,
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
			throw new Exception("Feature set '" ~ feature ~ "' not in this version of serve-d");
	trace("Features fulfilled");

	auto input = new FileReader(stdin);
	input.start();
	scope (exit)
		input.stop();
	trace("Started reading from stdin");

	rpc = new RPCProcessor(input, stdout);
	rpc.call();
	trace("RPC started");

	fibers ~= rpc;

	served.extension.spawnFiber = (&pushFiber!(void delegate())).toDelegate;
	pushFiber(&served.extension.parallelMain);

	while (rpc.state != Fiber.State.TERM)
	{
		while (rpc.hasData)
		{
			auto msg = rpc.poll;
			// Log on client side instead! (vscode setting: "serve-d.trace.server": "verbose")
			//trace("Message: ", msg);
			if (msg.id.hasData)
				pushFiber({
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
				});
			else
				pushFiber({
					try
					{
						processNotify(msg);
					}
					catch (Throwable e)
					{
						error("Failed processing notification: ", e);
					}
				});
		}
		Thread.sleep(10.msecs);
		synchronized (fibersMutex)
			fibers.call();
	}

	return served.extension.shutdownRequested ? 0 : 1;
}

__gshared Mutex fibersMutex;
void pushFiber(T)(T callback)
{
	synchronized (fibersMutex)
		fibers ~= new Fiber(callback, 4096 * 16);
}
