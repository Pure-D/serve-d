module served.dcd.client;

@safe:

import core.time;
import core.sync.mutex;

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.process;
import std.socket;
import std.stdio;
import std.string;

import dcd.common.messages;
import dcd.common.dcd_version;
import dcd.common.socket;

version (OSX) version = haveUnixSockets;
version (linux) version = haveUnixSockets;
version (BSD) version = haveUnixSockets;
version (FreeBSD) version = haveUnixSockets;

public import dcd.common.messages :
	DCDResponse = AutocompleteResponse,
	DCDCompletionType = CompletionType,
	isDCDServerRunning = serverIsRunning;

version (haveUnixSockets)
	enum platformSupportsDCDUnixSockets = true;
else
	enum platformSupportsDCDUnixSockets = false;

interface IDCDClient
{
	string socketFile() const @property;
	void socketFile(string) @property;
	ushort runningPort() const @property;
	void runningPort(ushort) @property;
	bool usingUnixDomainSockets() const @property;

	bool queryRunning();
	bool shutdown();
	bool clearCache();
	bool addImportPaths(string[] importPaths);
	bool removeImportPaths(string[] importPaths);
	string[] listImportPaths();
	SymbolInformation requestSymbolInfo(CodeRequest loc);
	string[] requestDocumentation(CodeRequest loc);
	DCDResponse.Completion[] requestSymbolSearch(string query);
	LocalUse requestLocalUse(CodeRequest loc);
	Completion requestAutocomplete(CodeRequest loc);
}

class ExternalDCDClient : IDCDClient
{
	string clientPath;
	ushort _runningPort;
	string _socketFile;

	this(string clientPath)
	{
		this.clientPath = clientPath;
	}

	string socketFile() const @property
	{
		return _socketFile;
	}

	void socketFile(string value) @property
	{
		_socketFile = value;
	}

	ushort runningPort() const @property
	{
		return _runningPort;
	}

	void runningPort(ushort value) @property
	{
		_runningPort = value;
	}

	bool usingUnixDomainSockets() const @property
	{
		version (haveUnixSockets)
			return true;
		else
			return false;
	}

	bool queryRunning()
	{
		return doClient(["--query"]).pid.wait == 0;
	}

	bool shutdown()
	{
		return doClient(["--shutdown"]).pid.wait == 0;
	}

	bool clearCache()
	{
		return doClient(["--clearCache"]).pid.wait == 0;
	}

	bool addImportPaths(string[] importPaths)
	{
		string[] args;
		foreach (path; importPaths)
			if (path.length)
				args ~= "-I" ~ path;
		return execClient(args).status == 0;
	}

	bool removeImportPaths(string[] importPaths)
	{
		string[] args;
		foreach (path; importPaths)
			if (path.length)
				args ~= "-R" ~ path;
		return execClient(args).status == 0;
	}

	string[] listImportPaths()
	{
		auto pipes = doClient(["--listImports"]);
		scope (exit)
		{
			pipes.pid.wait();
			pipes.destroy();
		}
		pipes.stdin.close();
		auto results = appender!(string[]);
		while (pipes.stdout.isOpen && !pipes.stdout.eof)
		{
			results.put((() @trusted => pipes.stdout.readln())());
		}
		return results.data;
	}

	SymbolInformation requestSymbolInfo(CodeRequest loc)
	{
		auto pipes = doClient([
				"-c", loc.cursorPosition.to!string, "--symbolLocation"
				]);
		scope (exit)
		{
			pipes.pid.wait();
			pipes.destroy();
		}
		pipes.stdin.write(loc.sourceCode);
		pipes.stdin.close();
		string line = (() @trusted => pipes.stdout.readln())();
		if (line.length == 0)
			return SymbolInformation.init;
		string[] splits = line.chomp.split('\t');
		if (splits.length != 2)
			return SymbolInformation.init;
		SymbolInformation ret;
		ret.declarationFilePath = splits[0];
		if (ret.declarationFilePath == "stdin")
			ret.declarationFilePath = loc.fileName;
		ret.declarationLocation = splits[1].to!size_t;
		return ret;
	}

	string[] requestDocumentation(CodeRequest loc)
	{
		auto pipes = doClient(["--doc", "-c", loc.cursorPosition.to!string]);
		scope (exit)
		{
			pipes.pid.wait();
			pipes.destroy();
		}
		pipes.stdin.write(loc.sourceCode);
		pipes.stdin.close();
		string[] data;
		while (pipes.stdout.isOpen && !pipes.stdout.eof)
		{
			string line = (() @trusted => pipes.stdout.readln())();
			if (line.length)
				data ~= line.chomp.unescapeTabs;
		}
		return data;
	}

	DCDResponse.Completion[] requestSymbolSearch(string query)
	{
		auto pipes = doClient(["--search", query]);
		scope (exit)
		{
			pipes.pid.wait();
			pipes.destroy();
		}
		pipes.stdin.close();
		auto results = appender!(DCDResponse.Completion[]);
		while (pipes.stdout.isOpen && !pipes.stdout.eof)
		{
			string line = (() @trusted => pipes.stdout.readln())();
			if (line.length == 0)
				continue;
			string[] splits = line.chomp.split('\t');
			if (splits.length >= 3)
			{
				DCDResponse.Completion item;
				item.identifier = query; // hack
				item.kind = splits[1] == "" ? char.init : splits[1][0];
				item.symbolFilePath = splits[0];
				item.symbolLocation = splits[2].to!size_t;
				results ~= item;
			}
		}
		return results.data;
	}

	LocalUse requestLocalUse(CodeRequest loc)
	{
		auto pipes = doClient([
				"--localUse",
				"-c", loc.cursorPosition.to!string
			]);
		scope (exit)
		{
			pipes.pid.wait();
			pipes.destroy();
		}
		pipes.stdin.write(loc.sourceCode);
		pipes.stdin.close();
		
		string header = (() @trusted => pipes.stdout.readln())().chomp;
		if (header == "00000" || !header.length)
			return LocalUse.init;

		LocalUse ret;
		auto headerParts = header.split('\t');
		if (headerParts.length < 2)
			return LocalUse.init;

		ret.declarationFilePath = headerParts[0];
		ret.declarationLocation = headerParts[1].length ? headerParts[1].to!size_t : 0;
		while (pipes.stdout.isOpen && !pipes.stdout.eof)
		{
			string line = (() @trusted => pipes.stdout.readln())().chomp;
			if (line.length == 0)
				continue;
			ret.uses ~= line.to!size_t;
		}
		return ret;
	}

	Completion requestAutocomplete(CodeRequest loc)
	{
		auto pipes = doClient([
				"--extended",
				"-c", loc.cursorPosition.to!string
			]);
		scope (exit)
		{
			pipes.pid.wait();
			pipes.destroy();
		}
		pipes.stdin.write(loc.sourceCode);
		pipes.stdin.close();
		auto dataApp = appender!(string[]);
		while (pipes.stdout.isOpen && !pipes.stdout.eof)
		{
			string line = (() @trusted => pipes.stdout.readln())();
			if (line.length == 0)
				continue;
			dataApp ~= line.chomp;
		}

		string[] data = dataApp.data;
		auto symbols = appender!(DCDResponse.Completion[]);
		Completion c;
		if (data.length == 0)
		{
			c.type = CompletionType.identifiers;
			return c;
		}
		
		c.type = cast(CompletionType)data[0];
		if (c.type == CompletionType.identifiers
			|| c.type == CompletionType.calltips)
		{
			foreach (line; data[1 .. $])
			{
				string[] splits = line.split('\t');
				DCDResponse.Completion symbol;
				if (splits.length < 5)
					continue;
				string location = splits[3];
				string file;
				int index;
				if (location.length)
				{
					auto space = location.lastIndexOf(' ');
					if (space != -1)
					{
						file = location[0 .. space];
						if (location[space + 1 .. $].all!isDigit)
							index = location[space + 1 .. $].to!int;
					}
					else
						file = location;
				}
				symbol.identifier = splits[0];
				symbol.kind = splits[1] == "" ? char.init : splits[1][0];
				symbol.definition = splits[2];
				symbol.symbolFilePath = file;
				symbol.symbolLocation = index;
				symbol.documentation = splits[4].unescapeTabs;
				if (splits.length > 5)
					symbol.typeOf = splits[5];
				symbols ~= symbol;
			}
		}

		c.completions = symbols.data;
		return c;
	}

private:
	string[] clientArgs()
	{
		if (usingUnixDomainSockets)
			return ["--socketFile", socketFile];
		else
			return ["--port", runningPort.to!string];
	}

	auto doClient(string[] args)
	{
		return raw([clientPath] ~ clientArgs ~ args);
	}

	auto raw(string[] args, Redirect redirect = Redirect.all)
	{
		return pipeProcess(args, redirect, null, Config.none, null);
	}

	auto execClient(string[] args)
	{
		return rawExec([clientPath] ~ clientArgs ~ args);
	}

	auto rawExec(string[] args)
	{
		return execute(args, null, Config.none, size_t.max, null);
	}
}

class BuiltinDCDClient : IDCDClient
{
	public static enum minSupportedServerInclusive = [0, 8, 0];
	public static enum maxSupportedServerExclusive = [0, 14, 0];

	public static immutable clientVersion = DCD_VERSION;

	bool useTCP;
	string _socketFile;
	ushort port = DEFAULT_PORT_NUMBER;

	private Mutex socketMutex;
	private Socket socket = null;

	this()
	{
		version (haveUnixSockets)
		{
			this((() @trusted => generateSocketName())());
		}
		else
		{
			this(DEFAULT_PORT_NUMBER);
		}
	}

	this(string socketFile)
	{
		socketMutex = new Mutex();
		useTCP = false;
		this._socketFile = _socketFile;
	}

	this(ushort port)
	{
		socketMutex = new Mutex();
		useTCP = true;
		this.port = port;
	}

	string socketFile() const @property
	{
		return _socketFile;
	}

	void socketFile(string value) @property
	{
		version (haveUnixSockets)
		{
			if (value.length > 0)
				useTCP = false;
		}
		_socketFile = value;
	}

	ushort runningPort() const @property
	{
		return port;
	}

	void runningPort(ushort value) @property
	{
		if (value != 0)
			useTCP = true;
		port = value;
	}

	bool usingUnixDomainSockets() const @property
	{
		version (haveUnixSockets)
			return true;
		else
			return false;
	}

	bool queryRunning() @trusted
	{
		return serverIsRunning(useTCP, socketFile, port);
	}

	Socket connectForRequest()
	{
		socketMutex.lock();
		scope (failure)
		{
			socket = null;
			socketMutex.unlock();
		}

		assert(socket is null, "Didn't call closeRequestConnection but attempted to connect again");

		if (useTCP)
		{
			socket = new TcpSocket(AddressFamily.INET);
			socket.connect(new InternetAddress("127.0.0.1", port));
		}
		else
		{
			version (haveUnixSockets)
			{
				socket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
				socket.connect(new UnixAddress(socketFile));
			}
			else
			{
				// should never be called with non-null socketFile on Windows
				assert(false);
			}
		}

		socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, dur!"seconds"(
				5));
		socket.blocking = true;
		return socket;
	}

	void closeRequestConnection()
	{
		scope (exit)
		{
			socket = null;
			socketMutex.unlock();
		}

		socket.shutdown(SocketShutdown.BOTH);
		socket.close();
	}

	bool performNotification(AutocompleteRequest request) @trusted
	{
		auto sock = connectForRequest();
		scope (exit)
			closeRequestConnection();

		return sendRequest(sock, request);
	}

	DCDResponse performRequest(AutocompleteRequest request) @trusted
	{
		auto sock = connectForRequest();
		scope (exit)
			closeRequestConnection();

		if (!sendRequest(sock, request))
			throw new Exception("Failed to send request");

		try
		{
			return getResponse(sock);
		}
		catch (Exception e)
		{
			return DCDResponse.init;
		}
	}

	bool shutdown()
	{
		AutocompleteRequest request;
		request.kind = RequestKind.shutdown;
		return performNotification(request);
	}

	bool clearCache()
	{
		AutocompleteRequest request;
		request.kind = RequestKind.clearCache;
		return performNotification(request);
	}

	bool addImportPaths(string[] importPaths)
	{
		AutocompleteRequest request;
		request.kind = RequestKind.addImport;
		request.importPaths = importPaths;
		return performNotification(request);
	}

	bool removeImportPaths(string[] importPaths)
	{
		AutocompleteRequest request;
		request.kind = RequestKind.removeImport;
		request.importPaths = importPaths;
		return performNotification(request);
	}

	string[] listImportPaths()
	{
		AutocompleteRequest request;
		request.kind = RequestKind.listImports;
		return performRequest(request).importPaths;
	}

	SymbolInformation requestSymbolInfo(CodeRequest loc)
	{
		AutocompleteRequest request;
		request.kind = RequestKind.symbolLocation;
		loc.apply(request);
		return SymbolInformation(performRequest(request));
	}

	string[] requestDocumentation(CodeRequest loc)
	{
		AutocompleteRequest request;
		request.kind = RequestKind.doc;
		loc.apply(request);
		return performRequest(request).completions.map!"a.documentation".array;
	}

	DCDResponse.Completion[] requestSymbolSearch(string query)
	{
		AutocompleteRequest request;
		request.kind = RequestKind.search;
		request.searchName = query;
		return performRequest(request).completions;
	}

	LocalUse requestLocalUse(CodeRequest loc)
	{
		AutocompleteRequest request;
		request.kind = RequestKind.localUse;
		loc.apply(request);
		return LocalUse(performRequest(request));
	}

	Completion requestAutocomplete(CodeRequest loc)
	{
		AutocompleteRequest request;
		request.kind = RequestKind.autocomplete;
		loc.apply(request);
		return Completion(performRequest(request));
	}
}

struct CodeRequest
{
	string fileName;
	const(char)[] sourceCode;
	size_t cursorPosition = size_t.max;

	// private because sourceCode is const but in AutocompleteRequest it's not
	private void apply(ref AutocompleteRequest request)
	{
		request.fileName = fileName;
		// @trusted because the apply function is only used in places where we
		// know that the request is not used outside the CodeRequest scope.
		request.sourceCode = (() @trusted => cast(ubyte[]) sourceCode)();
		request.cursorPosition = cursorPosition;
	}
}

struct SymbolInformation
{
	string declarationFilePath;
	size_t declarationLocation;

	this(DCDResponse res)
	{
		declarationFilePath = res.symbolFilePath;
		declarationLocation = res.symbolLocation;
	}
}

struct Completion
{
	CompletionType type;
	DCDResponse.Completion[] completions;

	this(DCDResponse res)
	{
		type = cast(CompletionType) res.completionType;
		completions = res.completions;
	}
}

struct LocalUse
{
	string declarationFilePath;
	size_t declarationLocation;
	size_t[] uses;

	this(DCDResponse res)
	{
		declarationFilePath = res.symbolFilePath;
		declarationLocation = res.symbolLocation;
		uses = res.completions.map!"a.symbolLocation".array;
	}
}

private string unescapeTabs(string val)
{
	if (!val.length)
		return val;

	auto ret = appender!string;
	size_t i = 0;
	while (i < val.length)
	{
		size_t index = val.indexOf('\\', i);
		if (index == -1 || cast(int) index == cast(int) val.length - 1)
		{
			if (!ret.data.length)
			{
				return val;
			}
			else
			{
				ret.put(val[i .. $]);
				break;
			}
		}
		else
		{
			char c = val[index + 1];
			switch (c)
			{
			case 'n':
				c = '\n';
				break;
			case 't':
				c = '\t';
				break;
			default:
				break;
			}
			ret.put(val[i .. index]);
			ret.put(c);
			i = index + 2;
		}
	}
	return ret.data;
}

unittest
{
	shouldEqual("hello world", "hello world".unescapeTabs);
	shouldEqual("hello\nworld", "hello\\nworld".unescapeTabs);
	shouldEqual("hello\\nworld", "hello\\\\nworld".unescapeTabs);
	shouldEqual("hello\\\nworld", "hello\\\\\\nworld".unescapeTabs);
}
