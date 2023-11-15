module served.lsp.async_mockrpc;

version (unittest):

import core.time;
import std.algorithm;
import std.conv;
import std.string;

import eventcore.core;
import served.lsp.jsonrpc;
import served.utils.fibermanager;
import served.utils.filereader_async;

/// Helper struct to simulate RPC connections with an RPCProcessor.
/// Intended for use with tests, not for real-world use.
struct AsyncMockRPC
{
	import std.process;

	enum shortDelay = 50.msecs;

	Pipe rpcPipe;
	Pipe resultPipe;

	void writePacket(string s, string epilogue = "", string prologue = "")
	{
		with (rpcPipe.writeEnd.lockingBinaryWriter)
		{
			put(prologue);
			put("Content-Length: ");
			put(s.length.to!string);
			put("\r\n\r\n");
			put(s);
			put(epilogue);
		}
		rpcPipe.writeEnd.flush();
	}

	string readPacket()
	{
		auto lenStr = resultPipe.readEnd.readln();
		assert(lenStr.startsWith("Content-Length: "));
		auto len = lenStr["Content-Length: ".length .. $].strip.to!int;
		resultPipe.readEnd.readln();
		ubyte[] buf = new ubyte[len];
		size_t i;
		while (!resultPipe.readEnd.eof && i < buf.length)
			i += resultPipe.readEnd.rawRead(buf[i .. $]).length;
		assert(i == buf.length);
		return cast(string)buf;
	}

	void expectPacket(string s)
	{
		auto res = readPacket();
		assert(res == s, res);
	}

	void testRPC(void delegate(RPCProcessor rpc) cb)
	{
		rpcPipe = pipe();
		resultPipe = pipe();

		auto fiberManager = new shared FiberManager();
		_fiberManager = fiberManager;

		auto rpcInput = new EventcoreFileReader(rpcPipe.readEnd.fileno);
		auto rpc = new RPCProcessor(rpcInput, resultPipe.writeEnd);
		rpc.fibers = fiberManager;

		fiberManager.put(rpc);

		auto cbfib = new Fiber(() {
			cb(rpc);
			rpc.stop();
			await(shortDelay);
			fiberManager.stop();
		}, 1024 * 16);
		fiberManager.put(cbfib);

		fiberManager.run();

		assert(cbfib.state == Fiber.State.TERM);
		assert(rpc.state == Fiber.State.TERM);
	}
}

unittest
{
	import served.lsp.protocol;
	import std.stdio : stderr;
	import std.logger;

	globalLogLevel = LogLevel.trace;
	static if (__VERSION__ < 2101)
		sharedLog = new FileLogger(stderr);
	else
		sharedLog = (() @trusted => cast(shared) new FileLogger(stderr))();

	AsyncMockRPC mockRPC;

	void writePacket(string s, string epilogue = "", string prologue = "")
	{
		mockRPC.writePacket(s, epilogue, prologue);
	}

	string readPacket()
	{
		return mockRPC.readPacket();
	}

	void expectPacket(string s)
	{
		mockRPC.expectPacket(s);
	}

	void testRPC(void delegate(RPCProcessor rpc) cb, size_t line = __LINE__)
	{
		mockRPC.testRPC(cb);
	}

	testRPC((rpc) { /* test immediate close */ });

	foreach (i; 0 .. 2)
	testRPC((rpc) {
		InitializeParams initializeParams = {
			processId: 1234,
			rootUri: "file:///root/uri",
			capabilities: ClientCapabilities.init
		};
		auto tok = rpc.sendMethod("initialize", initializeParams);
		auto waitHandle = rpc.prepareWait(tok);
		expectPacket(`{"jsonrpc":"2.0","id":` ~ tok.value.toString ~ `,"method":"initialize","params":{"processId":1234,"rootUri":"file:///root/uri","capabilities":{}}}`);
		writePacket(`{"jsonrpc":"2.0","id":` ~ tok.value.toString ~ `,"result":{"capabilities":{}}}`);
		await(AsyncMockRPC.shortDelay);
		assert(rpc.hasResponse(waitHandle));
		auto res = rpc.resolveWait(waitHandle);
		assert(res.resultJson == `{"capabilities":{}}`);
	});

	// test close after unfinished message (e.g. client crashed)
	testRPC((rpc) {
		mockRPC.rpcPipe.writeEnd.lockingBinaryWriter.put("Content-Length: 5\r\n\r\n");
		mockRPC.rpcPipe.writeEnd.flush();
		await(AsyncMockRPC.shortDelay);
	});
	testRPC((rpc) {
		mockRPC.rpcPipe.writeEnd.lockingBinaryWriter.put("Content-Length: 5\r\n\r\ntrue");
		mockRPC.rpcPipe.writeEnd.flush();
		await(AsyncMockRPC.shortDelay);
	});

	// test unlucky buffering
	testRPC((rpc) {
		void slowIO()
		{
			await(AsyncMockRPC.shortDelay);
		}

		InitializeParams initializeParams = {
			processId: 1234,
			rootUri: "file:///root/uri",
			capabilities: ClientCapabilities.init
		};
		auto tok = rpc.sendMethod("initialize", initializeParams);
		auto waitHandle = rpc.prepareWait(tok);
		expectPacket(`{"jsonrpc":"2.0","id":` ~ tok.value.toString ~ `,"method":"initialize","params":{"processId":1234,"rootUri":"file:///root/uri","capabilities":{}}}`);
		auto s = `{"jsonrpc":"2.0","id":` ~ tok.value.toString ~ `,"result":{"capabilities":{}}}`;
		mockRPC.rpcPipe.writeEnd.lockingBinaryWriter.put("Content-Length: ");
		mockRPC.rpcPipe.writeEnd.flush();
		slowIO();
		assert(!rpc.hasResponse(waitHandle));
		mockRPC.rpcPipe.writeEnd.lockingBinaryWriter.put(s.length.to!string);
		mockRPC.rpcPipe.writeEnd.flush();
		slowIO();
		assert(!rpc.hasResponse(waitHandle));
		mockRPC.rpcPipe.writeEnd.lockingBinaryWriter.put("\r");
		mockRPC.rpcPipe.writeEnd.flush();
		slowIO();
		assert(!rpc.hasResponse(waitHandle));
		mockRPC.rpcPipe.writeEnd.lockingBinaryWriter.put("\n\r\n");
		mockRPC.rpcPipe.writeEnd.flush();
		slowIO();
		assert(!rpc.hasResponse(waitHandle));
		mockRPC.rpcPipe.writeEnd.lockingBinaryWriter.put(s[0 .. $ / 2]);
		mockRPC.rpcPipe.writeEnd.flush();
		slowIO();
		assert(!rpc.hasResponse(waitHandle));
		mockRPC.rpcPipe.writeEnd.lockingBinaryWriter.put(s[$ / 2 .. $]);
		mockRPC.rpcPipe.writeEnd.flush();
		slowIO();
		assert(rpc.hasResponse(waitHandle));
		auto res = rpc.resolveWait(waitHandle);
		assert(res.resultJson == `{"capabilities":{}}`);
	});

	// test spec-resiliance with whitespace before/after message
	foreach (pair; [["", "\r\n"], ["\r\n", ""], ["\r\n\r\n", "\r\n\r\n"]])
	testRPC((rpc) {
		InitializeParams initializeParams = {
			processId: 1234,
			rootUri: "file:///root/uri",
			capabilities: ClientCapabilities.init
		};
		auto tok = rpc.sendMethod("initialize", initializeParams);
		auto waitHandle = rpc.prepareWait(tok);
		expectPacket(`{"jsonrpc":"2.0","id":` ~ tok.value.toString ~ `,"method":"initialize","params":{"processId":1234,"rootUri":"file:///root/uri","capabilities":{}}}`);
		writePacket(`{"jsonrpc":"2.0","id":` ~ tok.value.toString ~ `,"result":{"capabilities":{}}}`, pair[1], pair[0]);
		await(AsyncMockRPC.shortDelay);
		assert(rpc.hasResponse(waitHandle));
		auto res = rpc.resolveWait(waitHandle);
		assert(res.resultJson == `{"capabilities":{}}`);

		writePacket(`{"jsonrpc":"2.0","id":"sendtest","method":"test","params":{"x":{"a":4}}}`, pair[1], pair[0]);
		await(AsyncMockRPC.shortDelay);
		assert(rpc.hasData);
		auto msg = rpc.poll;
		assert(!msg.id.isNone);
		assert(msg.id.deref == "sendtest");
		assert(msg.method == "test");
		assert(msg.paramsJson == `{"x":{"a":4}}`);
	});

	// test error handling
	testRPC((rpc) {
		InitializeParams initializeParams = {
			processId: 1234,
			rootUri: "file:///root/uri",
			capabilities: ClientCapabilities.init
		};
		auto tok = rpc.sendMethod("initialize", initializeParams);
		auto waitHandle = rpc.prepareWait(tok);
		expectPacket(`{"jsonrpc":"2.0","id":` ~ tok.value.toString ~ `,"method":"initialize","params":{"processId":1234,"rootUri":"file:///root/uri","capabilities":{}}}`);
		writePacket(`{"jsonrpc":"2.0","id":` ~ tok.value.toString ~ `,"result":{"capabilities":{}}}`);
		await(AsyncMockRPC.shortDelay);
		assert(rpc.hasResponse(waitHandle));
		auto res = rpc.resolveWait(waitHandle);
		assert(res.resultJson == `{"capabilities":{}}`);

		void errorTest(string send, string recv)
		{
			writePacket(send);
			await(AsyncMockRPC.shortDelay);
			expectPacket(recv);
		}

		errorTest(`{"jsonrpc":"2.0","id":"invalid-token","result":{"capabilities":{}}}`,
			`{"jsonrpc":"2.0","id":"invalid-token","error":{"code":-32600,"message":"unknown request response ID"}}`);

		// twice to see that the same error gets handled
		errorTest(`{"jsonrpc":"2.0","id":"invalid-token","result":{"capabilities":{}}}`,
			`{"jsonrpc":"2.0","id":"invalid-token","error":{"code":-32600,"message":"unknown request response ID"}}`);

		errorTest(`{"jsonrpc": "2.0", "method": "foobar, "params": "bar", "baz]`,
			`{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: malformed request JSON, must be object"}}`);

		errorTest(`[]`,
			`{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Empty batch request"}}`);

		errorTest(`[{}]`,
			`{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"missing required members or has ambiguous members"}}`);

		writePacket(`[{},{},{}]`);
		await(AsyncMockRPC.shortDelay);
		expectPacket(`{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"missing required members or has ambiguous members"}}`);
		expectPacket(`{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"missing required members or has ambiguous members"}}`);
		expectPacket(`{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"missing required members or has ambiguous members"}}`);
	});
}
