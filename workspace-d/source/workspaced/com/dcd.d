module workspaced.com.dcd;

import std.file : tempDir;

import core.thread;
import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.datetime;
import std.experimental.logger;
import std.experimental.logger : trace;
import std.json;
import std.path;
import std.process;
import std.random;
import std.stdio;
import std.string;
import std.typecons;

import painlessjson;

import workspaced.api;
import workspaced.helpers;
import workspaced.com.dcd_version;

import served.dcd.client;

@component("dcd")
class DCDComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	enum latestKnownVersion = latestKnownDCDVersion;
	void load()
	{
		installedVersion = workspaced.globalConfiguration.get("dcd", "_installedVersion", "");

		if (installedVersion.length
				&& this.clientPath == workspaced.globalConfiguration.get("dcd", "_clientPath", "")
				&& this.serverPath == workspaced.globalConfiguration.get("dcd", "_serverPath", ""))
		{
			if (workspaced.globalConfiguration.get("dcd", "_usingInternal", false))
				client = new BuiltinDCDClient();
			else
				client = new ExternalDCDClient(this.clientPath);
			trace("Reusing previously identified DCD ", installedVersion);
		}
		else
		{
			reloadBinaries();
		}
	}

	void reloadBinaries()
	{
		string clientPath = this.clientPath;
		string serverPath = this.serverPath;

		client = null;

		installedVersion = serverPath.getVersionAndFixPath;
		string serverPathInfo = serverPath != "dcd-server" ? "(" ~ serverPath ~ ") " : "";
		trace("Detected dcd-server ", serverPathInfo, installedVersion);

		if (!checkVersion(installedVersion, BuiltinDCDClient.minSupportedServerInclusive)
				|| checkVersion(installedVersion, BuiltinDCDClient.maxSupportedServerExclusive))
		{
			info("Using dcd-client instead of internal workspace-d client");

			string clientInstalledVersion = clientPath.getVersionAndFixPath;
			string clientPathInfo = clientPath != "dcd-client" ? "(" ~ clientPath ~ ") " : "";
			trace("Detected dcd-client ", clientPathInfo, clientInstalledVersion);

			if (clientInstalledVersion != installedVersion)
				throw new Exception("client & server version mismatch");

			client = new ExternalDCDClient(clientPath);
		}
		else
		{
			info("using builtin DCD client");
			client = new BuiltinDCDClient();
		}

		config.set("dcd", "clientPath", clientPath);
		config.set("dcd", "serverPath", serverPath);

		assert(this.clientPath == clientPath);
		assert(this.serverPath == serverPath);

		//dfmt off
		if (isOutdated)
			workspaced.broadcast(refInstance, JSONValue([
				"type": JSONValue("outdated"),
				"component": JSONValue("dcd")
			]));
		//dfmt on

		workspaced.globalConfiguration.set("dcd", "_usingInternal",
				cast(ExternalDCDClient) client ? false : true);
		workspaced.globalConfiguration.set("dcd", "_clientPath", clientPath);
		workspaced.globalConfiguration.set("dcd", "_serverPath", serverPath);
		workspaced.globalConfiguration.set("dcd", "_installedVersion", installedVersion);
	}

	/// Returns: true if DCD version is less than latestKnownVersion or if server and client mismatch or if it doesn't exist.
	bool isOutdated()
	{
		if (!installedVersion)
		{
			string serverPath = this.serverPath;

			try
			{
				installedVersion = serverPath.getVersionAndFixPath;
			}
			catch (ProcessException)
			{
				return true;
			}
		}

		if (installedVersion.isLocallyCompiledDCD)
			return false;

		return !checkVersion(installedVersion, latestKnownVersion);
	}

	/// Returns: The current detected installed version of dcd-client.
	///          Ends with `"-workspaced-builtin"` if this is using the builtin
	///          client.
	string clientInstalledVersion() @property const
	{
		return cast(ExternalDCDClient) client ? installedVersion :
			BuiltinDCDClient.clientVersion ~ "-workspaced-builtin";
	}

	/// Returns: The current detected installed version of dcd-server. `null` if
	///          none is installed.
	string serverInstalledVersion() const
	{
		if (!installedVersion)
		{
			string serverPath = this.serverPath;

			try
			{
				return serverPath.getVersionAndFixPath;
			}
			catch (ProcessException)
			{
				return null;
			}
		}

		return installedVersion;
	}

	private auto serverThreads()
	{
		return threads(1, 2);
	}

	/// This stops the dcd-server instance safely and waits for it to exit
	override void shutdown(bool dtor = false)
	{
		stopServerSync();
		if (!dtor && _threads)
			serverThreads.finish();
	}

	/// This will start the dcd-server and load import paths from the current provider
	void setupServer(string[] additionalImports = [], bool quietServer = false)
	{
		startServer(importPaths ~ importFiles ~ additionalImports, quietServer);
	}

	/// This will start the dcd-server. If DCD does not support IPC sockets on
	/// this platform, will use the TCP port specified with the `port` property
	/// or init config.
	///
	/// Throws an exception if a TCP port is used and another server is already
	/// running on it.
	///
	/// Params:
	///   additionalImports = import paths to cache on the server on startup.
	///   quietServer = if true: no output from DCD server is processed,
	///                 if false: every line will be traced to the output.
	///   selectPort = if true, increment port until an open one is found
	///                instead of throwing an exception.
	void startServer(string[] additionalImports = [], bool quietServer = false, bool selectPort = false)
	{
		ushort port = this.port;
		while (port + 1 < ushort.max && isPortRunning(port))
		{
			if (selectPort)
				port++;
			else
				throw new Exception("Already running dcd on port " ~ port.to!string);
		}
		string[] imports;
		foreach (i; additionalImports)
			if (i.length)
				imports ~= "-I" ~ i;

		client.runningPort = port;
		client.socketFile = buildPath(tempDir,
				"workspace-d-sock" ~ thisProcessID.to!string ~ "-" ~ uniform!ulong.to!string(36));

		string[] serverArgs;
		static if (platformSupportsDCDUnixSockets)
			serverArgs = [serverPath, "--socketFile", client.socketFile];
		else
			serverArgs = [serverPath, "--port", client.runningPort.to!string];

		serverPipes = raw(serverArgs ~ imports,
				Redirect.stdin | Redirect.stderr | Redirect.stdoutToStderr);
		while (!serverPipes.stderr.eof)
		{
			string line = serverPipes.stderr.readln();
			if (!quietServer)
				trace("Server: ", line);
			if (line.canFind("Startup completed in "))
				break;
		}
		running = true;
		serverThreads.create({
			mixin(traceTask);
			scope (exit)
				running = false;

			try
			{
				if (quietServer)
					foreach (block; serverPipes.stderr.byChunk(4096))
					{
					}
				else
					while (serverPipes.stderr.isOpen && !serverPipes.stderr.eof)
					{
						auto line = serverPipes.stderr.readln();
						trace("Server: ", line); // evaluates lazily, so read before
					}
			}
			catch (Exception e)
			{
				error("Reading/clearing stderr from dcd-server crashed (-> killing dcd-server): ", e);
				serverPipes.pid.kill();
			}

			auto code = serverPipes.pid.wait();
			info("DCD-Server stopped with code ", code);
			if (code != 0)
			{
				info("Broadcasting dcd server crash.");
				workspaced.broadcast(refInstance, JSONValue([
						"type": JSONValue("crash"),
						"component": JSONValue("dcd")
					]));
			}
		});
	}

	void stopServerSync()
	{
		if (!running)
			return;
		int i = 0;
		running = false;
		client.shutdown();
		while (serverPipes.pid && !serverPipes.pid.tryWait().terminated)
		{
			Thread.sleep(10.msecs);
			if (++i > 200) // Kill after 2 seconds
			{
				killServer();
				return;
			}
		}
	}

	/// This stops the dcd-server asynchronously
	/// Returns: null
	Future!void stopServer()
	{
		auto ret = new typeof(return)();
		gthreads.create({
			mixin(traceTask);
			try
			{
				stopServerSync();
				ret.finish();
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// This will kill the process associated with the dcd-server instance
	void killServer()
	{
		if (serverPipes.pid && !serverPipes.pid.tryWait().terminated)
			serverPipes.pid.kill();
	}

	/// This will stop the dcd-server safely and restart it again using setup-server asynchronously
	/// Returns: null
	Future!void restartServer(bool quiet = false)
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				stopServerSync();
				setupServer([], quiet);
				ret.finish();
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// This will query the current dcd-server status
	/// Returns: `{isRunning: bool}` If the dcd-server process is not running
	/// anymore it will return isRunning: false. Otherwise it will check for
	/// server status using `dcd-client --query` (or using builtin equivalent)
	auto serverStatus() @property
	{
		DCDServerStatus status;
		if (serverPipes.pid && serverPipes.pid.tryWait().terminated)
			status.isRunning = false;
		else if (client.usingUnixDomainSockets)
			status.isRunning = true;
		else
			status.isRunning = client.queryRunning();
		return status;
	}

	/// Searches for a symbol across all files using `dcd-client --search`
	Future!(DCDSearchResult[]) searchSymbol(string query)
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				if (!running)
				{
					ret.finish(null);
					return;
				}

				ret.finish(client.requestSymbolSearch(query)
					.map!(a => DCDSearchResult(a.symbolFilePath,
					cast(int)a.symbolLocation, [cast(char) a.kind].idup)).array);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// Reloads import paths from the current provider. Call reload there before calling it here.
	void refreshImports()
	{
		addImports(importPaths ~ importFiles);
	}

	/// Manually adds import paths as string array
	void addImports(string[] imports)
	{
		imports.sort!"a<b";
		knownImports = multiwayUnion([knownImports.filterNonEmpty, imports.filterNonEmpty]).array;
		updateImports();
	}

	/// Manually removes import paths using a string array. Note that trying to
	/// remove import paths from the import paths provider will result in them
	/// being readded as soon as refreshImports is called again.
	void removeImports(string[] imports)
	{
		knownImports = setDifference(knownImports, imports.filterNonEmpty).array;
		updateImports();
	}

	string clientPath() @property @ignoredFunc const
	{
		return config.get("dcd", "clientPath", "dcd-client");
	}

	string serverPath() @property @ignoredFunc const
	{
		return config.get("dcd", "serverPath", "dcd-server");
	}

	ushort port() @property @ignoredFunc const
	{
		return cast(ushort) config.get!int("dcd", "port", 9166);
	}

	/// Searches for an open port to spawn dcd-server in asynchronously starting with `port`, always increasing by one.
	/// Returns: 0 if not available, otherwise the port as number
	Future!ushort findAndSelectPort(ushort port = 9166)
	{
		if (client.usingUnixDomainSockets)
		{
			return typeof(return).fromResult(0);
		}
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				auto newPort = findOpen(port);
				port = newPort;
				ret.finish(port);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// Finds the declaration of the symbol at position `pos` in the code
	Future!DCDDeclaration findDeclaration(scope const(char)[] code, int pos)
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				if (!running || pos >= code.length)
				{
					ret.finish(DCDDeclaration.init);
					return;
				}

				// We need to move by one character on identifier characters to ensure the start character fits.
				if (!isIdentifierSeparatingChar(code[pos]))
					pos++;

				auto info = client.requestSymbolInfo(CodeRequest("stdin", code, pos));
				ret.finish(DCDDeclaration(info.declarationFilePath,
					cast(int) info.declarationLocation));
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// Finds the documentation of the symbol at position `pos` in the code
	Future!string getDocumentation(scope const(char)[] code, int pos)
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				if (!running)
				{
					ret.finish("");
					return;
				}
				auto doc = client.requestDocumentation(CodeRequest("stdin", code, pos));
				ret.finish(doc.join("\n"));
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// Finds declaration and usage of the token at position `pos` within the
	/// current document.
	Future!DCDLocalUse findLocalUse(scope const(char)[] code, int pos)
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				if (!running || pos >= code.length)
				{
					ret.finish(DCDLocalUse.init);
					return;
				}

				// We need to move by one character on identifier characters to ensure the start character fits.
				if (!isIdentifierSeparatingChar(code[pos]))
					pos++;

				auto localUse = client.requestLocalUse(CodeRequest("stdin", code, pos));
				ret.finish(DCDLocalUse(localUse));
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// Returns the used socket file. Only available on OSX, linux and BSD with DCD >= 0.8.0
	/// Throws an error if not available.
	string getSocketFile()
	{
		if (!client.usingUnixDomainSockets)
			throw new Exception("Unix domain sockets not supported");
		return client.socketFile;
	}

	/// Returns the used running port. Throws an error if using unix sockets instead
	ushort getRunningPort()
	{
		if (client.usingUnixDomainSockets)
			throw new Exception("Using unix domain sockets instead of a port");
		return client.runningPort;
	}

	/// Queries for code completion at position `pos` in code
	/// Raw is anything else than identifiers and calltips which might not be implemented by this point.
	/// calltips.symbols and identifiers.definition, identifiers.file, identifiers.location and identifiers.documentation are only available with dcd ~master as of now.
	Future!DCDCompletions listCompletion(scope const(char)[] code, int pos)
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				DCDCompletions completions;
				if (!running)
				{
					info("DCD not running!");
					ret.finish(completions);
					return;
				}

				auto c = client.requestAutocomplete(CodeRequest("stdin", code, pos));
				if (c.type == DCDCompletionType.calltips)
				{
					completions.type = DCDCompletions.Type.calltips;
					auto calltips = appender!(string[]);
					auto symbols = appender!(DCDCompletions.Symbol[]);
					foreach (item; c.completions)
					{
						calltips ~= item.definition;
						symbols ~= DCDCompletions.Symbol(item.symbolFilePath,
							cast(int)item.symbolLocation, item.documentation);
					}
					completions._calltips = calltips.data;
					completions._symbols = symbols.data;
				}
				else if (c.type == DCDCompletionType.identifiers)
				{
					completions.type = DCDCompletions.Type.identifiers;
					auto identifiers = appender!(DCDIdentifier[]);
					foreach (item; c.completions)
					{
						identifiers ~= DCDIdentifier(item.identifier,
							item.kind == char.init ? "" : [cast(char)item.kind].idup,
							item.definition, item.symbolFilePath,
							cast(int)item.symbolLocation, item.documentation);
					}
					completions._identifiers = identifiers.data;
				}
				else
				{
					completions.type = DCDCompletions.Type.raw;
					warning("Unknown DCD completion type: ", c.type);
				}
				ret.finish(completions);
			}
			catch (Throwable e)
			{
				ret.error(e);
			}
		});
		return ret;
	}

	void updateImports()
	{
		if (!running)
			return;

		auto existing = client.listImportPaths();
		existing.sort!"a<b";
		auto toAdd = setDifference(knownImports, existing);
		client.addImportPaths(toAdd.array);
	}

	bool fromRunning(bool supportsFullOutput, string socketFile, ushort runningPort)
	{
		if (socketFile.length ? isSocketRunning(socketFile) : isPortRunning(runningPort))
		{
			running = true;
			client.socketFile = socketFile;
			client.runningPort = runningPort;
			return true;
		}
		else
			return false;
	}

	deprecated("clients without full output support no longer supported") bool getSupportsFullOutput() @property
	{
		return true;
	}

	bool isUsingUnixDomainSockets() @property
	{
		return client.usingUnixDomainSockets;
	}

	bool isActive() @property
	{
		return running;
	}

private:
	string installedVersion;
	bool running = false;
	ProcessPipes serverPipes;
	string[] knownImports;
	IDCDClient client = new NullDCDClient();

	auto raw(string[] args, Redirect redirect = Redirect.all)
	{
		return pipeProcess(args, redirect, null, Config.none, refInstance ? instance.cwd : null);
	}

	auto rawExec(string[] args)
	{
		return execute(args, null, Config.none, size_t.max, refInstance ? instance.cwd : null);
	}

	bool isSocketRunning(string socket)
	{
		static if (!platformSupportsDCDUnixSockets)
			return false;
		else
			return isDCDServerRunning(false, socket, 0);
	}

	bool isPortRunning(ushort port)
	{
		static if (platformSupportsDCDUnixSockets)
			return false;
		else
			return isDCDServerRunning(true, null, port);
	}

	ushort findOpen(ushort port)
	{
		--port;
		bool isRunning;
		do
		{
			isRunning = isPortRunning(++port);
		}
		while (isRunning);
		return port;
	}
}

class NullDCDClient : IDCDClient
{
	enum Methods = [
		"string socketFile() const @property",
		"void socketFile(string) @property",
		"ushort runningPort() const @property",
		"void runningPort(ushort) @property",
		"bool usingUnixDomainSockets() const @property",
		"bool queryRunning()",
		"bool shutdown()",
		"bool clearCache()",
		"bool addImportPaths(string[] importPaths)",
		"bool removeImportPaths(string[] importPaths)",
		"string[] listImportPaths()",
		"SymbolInformation requestSymbolInfo(CodeRequest loc)",
		"string[] requestDocumentation(CodeRequest loc)",
		"DCDResponse.Completion[] requestSymbolSearch(string query)",
		"LocalUse requestLocalUse(CodeRequest loc)",
		"Completion requestAutocomplete(CodeRequest loc)",
	];

	static foreach (method; Methods)
	{
		mixin(method, " {
			import std.experimental.logger : warningf;
			warningf(\"Trying to use DCD function %s on uninitialized client!\", __FUNCTION__);
			static if (!is(typeof(return) == void))
				return typeof(return).init;
		}");
	}
}

bool supportsUnixDomainSockets(string ver)
{
	return checkVersion(ver, [0, 8, 0]);
}

unittest
{
	assert(supportsUnixDomainSockets("0.8.0-beta2+9ec55f40a26f6bb3ca95dc9232a239df6ed25c37"));
	assert(!supportsUnixDomainSockets("0.7.9-beta3"));
	assert(!supportsUnixDomainSockets("0.7.0"));
	assert(supportsUnixDomainSockets("v0.9.8 c7ea7e081ed9ad2d85e9f981fd047d7fcdb2cf51"));
	assert(supportsUnixDomainSockets("1.0.0"));
}

/// Returned by findDeclaration
struct DCDDeclaration
{
	string file;
	int position;
}

/// Returned by listCompletion
/// When identifiers: `{type:"identifiers", identifiers:[{identifier:string, type:string, definition:string, file:string, location:number, documentation:string}]}`
/// When calltips: `{type:"calltips", calltips:[string], symbols:[{file:string, location:number, documentation:string}]}`
/// When raw: `{type:"raw", raw:[string]}`
struct DCDCompletions
{
	/// Type of a completion
	enum Type
	{
		/// Unknown/Unimplemented output
		raw,
		/// Completion after a dot or a variable name
		identifiers,
		/// Completion for arguments in a function call
		calltips,
	}

	struct Symbol
	{
		string file;
		int location;
		string documentation;
	}

	/// Type of the completion (identifiers, calltips, raw)
	Type type;
	deprecated string[] raw;
	union
	{
		DCDIdentifier[] _identifiers;
		struct
		{
			string[] _calltips;
			Symbol[] _symbols;
		}
	}

	enum DCDCompletions empty = DCDCompletions(Type.identifiers);

	/// Only set with type==identifiers.
	inout(DCDIdentifier[]) identifiers() inout @property
	{
		if (type != Type.identifiers)
			throw new Exception("Type is not identifiers but attempted to access identifiers");
		return _identifiers;
	}

	/// Only set with type==calltips.
	inout(string[]) calltips() inout @property
	{
		if (type != Type.calltips)
			throw new Exception("Type is not calltips but attempted to access calltips");
		return _calltips;
	}

	/// Only set with type==calltips.
	inout(Symbol[]) symbols() inout @property
	{
		if (type != Type.calltips)
			throw new Exception("Type is not calltips but attempted to access symbols");
		return _symbols;
	}
}

/// Returned by findLocalUse
struct DCDLocalUse
{
	/// File path of the declaration or stdin for input
	string declarationFilePath;
	/// Byte location of the declaration inside the declarationFilePath
	size_t declarationLocation;
	/// Array of uses within stdin / given document.
	size_t[] uses;

	this(LocalUse localUse)
	{
		foreach (i, ref v; localUse.tupleof)
			this.tupleof[i] = v;
	}
}

/// Returned by status
struct DCDServerStatus
{
	///
	bool isRunning;
}

/// Type of the identifiers value in listCompletion
struct DCDIdentifier
{
	///
	string identifier;
	///
	string type;
	///
	string definition;
	///
	string file;
	/// byte location
	int location;
	///
	string documentation;
}

/// Returned by search-symbol
struct DCDSearchResult
{
	///
	string file;
	///
	int position;
	///
	string type;
}

private auto filterNonEmpty(T)(T range)
{
	return range.filter!(a => a.length);
}
