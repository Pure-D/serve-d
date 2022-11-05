module served.lsp.jsonrpc;

// version = TracePackets;

import core.exception;
import core.thread;

import std.container : DList;
import std.conv;
import std.experimental.logger;
import std.json;
import std.stdio;
import std.string;

import served.lsp.filereader;
import served.lsp.protocol;

/// Fiber which runs in the background, reading from a FileReader, and calling methods when requested over the RPC interface.
class RPCProcessor : Fiber
{
	/// Constructs this RPC processor using a FileReader to read RPC commands from and a std.stdio.File to write RPC commands to.
	/// Creates this fiber with a reasonable fiber size.
	this(FileReader reader, File writer)
	{
		super(&run, 4096 * 32);
		this.reader = reader;
		this.writer = writer;
	}

	/// Instructs the RPC processor to stop at the next IO read instruction.
	void stop()
	{
		stopped = true;
	}

	/// Sends an RPC response or error.
	/// If `result` or `error` is not given on the response message, they won't be sent.
	/// Otherwise on success `result` must be set or on error `error` must be set.
	/// This also logs the error to stderr if it is given.
	/// Params:
	///   res = the response message to send.
	void send(ResponseMessage res)
	{
		const(char)[][7] buf;
		int len;
		buf[len++] = `{"jsonrpc":"2.0","id":`;
		buf[len++] = res.id.serializeJson;

		if (!res.result.isNone)
		{
			buf[len++] = `,"result":`;
			buf[len++] = res.result.serializeJson;
		}

		if (!res.error.isNone)
		{
			buf[len++] = `,"error":`;
			buf[len++] = res.error.serializeJson;
			stderr.writeln(buf[len - 1]);
		}

		buf[len++] = `}`;
		sendRawPacket(buf[0 .. len]);
	}
	/// ditto
	void send(ResponseMessageRaw res)
	{
		const(char)[][7] buf;
		int len;
		buf[len++] = `{"jsonrpc":"2.0","id":`;
		buf[len++] = res.id.serializeJson;

		if (res.resultJson.length)
		{
			buf[len++] = `,"result":`;
			buf[len++] = res.resultJson;
		}

		if (!res.error.isNone)
		{
			buf[len++] = `,"error":`;
			buf[len++] = res.error.serializeJson;
			stderr.writeln(buf[len - 1]);
		}

		buf[len++] = `}`;
		sendRawPacket(buf[0 .. len]);
	}

	/// Sends an RPC request (method call) to the other side. Doesn't do any additional processing.
	/// Params:
	///   req = The request to send
	void send(RequestMessage req)
	{
		sendRawPacket(req.serializeJson);
	}

	/// ditto
	void send(RequestMessageRaw req)
	{
		int i;
		const(char)[][7] buffer;
		buffer[i++] = `{"jsonrpc":"2.0","method":`;
		buffer[i++] = req.method.serializeJson;
		if (!req.id.isNone)
		{
			buffer[i++] = `,"id":`;
			buffer[i++] = req.id.serializeJson;
		}
		if (req.paramsJson.length)
		{
			buffer[i++] = `,"params":`;
			buffer[i++] = req.paramsJson;
		}
		buffer[i++] = `}`;
		sendRawPacket(buffer[0 .. i]);
	}

	/// Sends a raw JSON object to the other RPC side. 
	deprecated void send(JSONValue raw)
	{
		if (!("jsonrpc" in raw))
		{
			error(raw);
			throw new Exception("Sent objects must have a jsonrpc");
		}
		const content = raw.toString(JSONOptions.doNotEscapeSlashes);
		sendRawPacket(content);
	}

	/// ditto
	void sendRawPacket(scope const(char)[] rawJson)
	{
		sendRawPacket((&rawJson)[0 .. 1]);
	}

	/// ditto
	void sendRawPacket(scope const(char)[][] parts)
	{
		// Consider turning on logging on client side instead!
		// (vscode setting: "serve-d.trace.server": "verbose")
		version (TracePackets)
		{
			import std.algorithm;

			trace(">> ", parts.join);
		}

		size_t len = 0;
		foreach (part; parts)
			len += part.length;

		{
			scope w = writer.lockingBinaryWriter;
			w.put("Content-Length: ");
			w.put(len.to!string);
			w.put("\r\n\r\n");
			foreach (part; parts)
				w.put(part);
		}
		writer.flush();
	}

	/// Sends a notification with the given `method` name to the other RPC side without any parameters.
	void notifyMethod(string method)
	{
		RequestMessageRaw req;
		req.method = method;
		send(req);
	}

	/// Sends a notification with the given `method` name to the other RPC side with the given `value` parameter serialized to JSON.
	void notifyMethod(T)(string method, T value)
	{
		notifyMethodRaw(method, value.serializeJson);
	}

	/// ditto
	deprecated void notifyMethod(string method, JSONValue value)
	{
		notifyMethodRaw(method, value.toString);
	}

	/// ditto
	void notifyMethod(string method, JsonValue value)
	{
		RequestMessage req;
		req.method = method;
		req.params = value;
		send(req);
	}

	/// ditto
	void notifyMethodRaw(string method, scope const(char)[] value)
	{
		const(char)[][5] parts = [
			`{"jsonrpc":"2.0","method":`,
			method.serializeJson,
			`,"params":`,
			value,
			`}`
		];
		sendRawPacket(parts[]);
	}

	void notifyProgressRaw(scope const(char)[] token, scope const(char)[] value)
	{
		const(char)[][5] parts = [
			`{"jsonrpc":"2.0","method":"$/progress","params":{"token":`,
			token,
			`,"value":`,
			value,
			`}}`
		];
		sendRawPacket(parts[]);
	}

	void registerCapability(T)(scope const(char)[] id, scope const(char)[] method, T options)
	{
		const(char)[][7] parts = [
			`{"jsonrpc":"2.0","method":"client/registerCapability","registrations":[{"id":"`,
			id.escapeJsonStringContent,
			`","method":"`,
			method.escapeJsonStringContent,
			`","registerOptions":`,
			options.serializeJson,
			`]}`
		];
		sendRawPacket(parts[]);
	}

	/// Sends a request with the given `method` name to the other RPC side without any parameters.
	/// Doesn't handle the response by the other RPC side.
	/// Returns: a RequestToken to use with $(LREF awaitResponse) to get the response. Can be ignored if the response isn't important.
	RequestToken sendMethod(string method)
	{
		auto id = RequestToken.randomLong();
		const(char)[][5] parts = [
			`{"jsonrpc":"2.0","id":`,
			id.serializeJson,
			`,"method":`,
			method.serializeJson,
			`}`
		];
		sendRawPacket(parts[]);
		return id;
	}

	/// Sends a request with the given `method` name to the other RPC side with the given `value` parameter serialized to JSON.
	/// Doesn't handle the response by the other RPC side.
	/// Returns: a RequestToken to use with $(LREF awaitResponse) to get the response. Can be ignored if the response isn't important.
	RequestToken sendMethod(T)(string method, T value)
	{
		return sendMethodRaw(method, value.serializeJson);
	}

	/// ditto
	deprecated RequestToken sendMethod(string method, JSONValue value)
	{
		return sendMethod(method, value.toJsonValue);
	}

	/// ditto
	RequestToken sendMethod(string method, JsonValue value)
	{
		return sendMethodRaw(method, value.serializeJson);
	}

	/// ditto
	RequestToken sendMethodRaw(string method, scope const(char)[] value)
	{
		auto id = RequestToken.randomLong();
		const(char)[][7] parts = [
			`{"jsonrpc":"2.0","id":`,
			id.serializeJson,
			`,"method":`,
			method.serializeJson,
			`,"params":`,
			value,
			`}`
		];
		sendRawPacket(parts[]);
		return id;
	}

	/// Sends a request with the given `method` name to the other RPC side with the given `value` parameter serialized to JSON.
	/// Awaits the response (using yield) and returns once it's there.
	///
	/// This is a small wrapper to call `awaitResponse(sendMethod(method, value))`
	///
	/// Returns: The response deserialized from the RPC.
	ResponseMessageRaw sendRequest(T)(string method, T value, Duration timeout = Duration.max)
	{
		return awaitResponse(sendMethod(method, value), timeout);
	}

	/// ditto
	deprecated ResponseMessageRaw sendRequest(string method, JSONValue value, Duration timeout = Duration.max)
	{
		return awaitResponse(sendMethod(method, value), timeout);
	}

	/// ditto
	ResponseMessageRaw sendRequest(string method, JsonValue value, Duration timeout = Duration.max)
	{
		return awaitResponse(sendMethod(method, value), timeout);
	}

	/// Calls the `window/logMessage` method with all arguments concatenated together using text()
	/// Params:
	///   type = the $(REF MessageType, served,lsp,protocol) to use as $(REF LogMessageParams, served,lsp,protocol) type
	///   args = the message parts to send
	void log(MessageType type = MessageType.log, Args...)(Args args)
	{
		scope const(char)[][3] parts = [
			`{"jsonrpc":"2.0","method":"window/logMessage","params":`,
			LogMessageParams(type, text(args)).serializeJson,
			`}`
		];
		sendRawPacket(parts[]);
	}

	/// Returns: `true` if there has been any messages been sent to us from the other RPC side, otherwise `false`.
	bool hasData() const @property
	{
		return !messageQueue.empty;
	}

	/// Returns: the first message from the message queue. Removes it from the message queue so it will no longer be processed.
	/// Throws: Exception if $(LREF hasData) is false.
	RequestMessageRaw poll()
	{
		if (!hasData)
			throw new Exception("No Data");
		auto ret = messageQueue.front;
		messageQueue.removeFront();
		return ret;
	}

	/// Convenience wrapper around $(LREF WindowFunctions) for `this`.
	WindowFunctions window()
	{
		return WindowFunctions(this);
	}

	/// Registers a wait handler for the given request token. When the other RPC
	/// side sends a response to this token, the value will be saved, before it
	/// is being awaited.
	private size_t prepareWait(RequestToken tok)
	{
		size_t i;
		bool found = false;
		foreach (n, t; responseTokens)
		{
			if (t.handled)
			{
				// replace handled responses (overwrite reusable memory)
				i = n;
				found = true;
				break;
			}
		}
		if (!found)
			i = responseTokens.length++;
		responseTokens[i] = RequestWait(tok);
		return i;
	}

	/// Waits until the given responseToken wait handler is resolved, then
	/// return its result and makes the memory reusable.
	private ResponseMessageRaw resolveWait(size_t i, Duration timeout = Duration.max)
	{
		import std.datetime.stopwatch;

		StopWatch sw;
		sw.start();
		while (!responseTokens[i].got)
		{
			if (timeout != Duration.max
				&& sw.peek > timeout)
				throw new Exception("RPC response wait timed out");
			yield(); // yield until main loop placed a response
		}
		auto res = responseTokens[i].ret;
		responseTokens[i].handled = true; // make memory reusable
		return res;
	}

	private bool hasResponse(size_t handle)
	{
		return responseTokens[handle].got;
	}

	/**
		Waits for a response message to a request from the other RPC side.

		If this is called after the response has already been sent and processed
		by yielding after sending the request, this will yield forever and use
		up memory.

		So it is important, if you are going to await a response, to do it
		immediately when sending any request.
	*/
	ResponseMessageRaw awaitResponse(RequestToken tok, Duration timeout = Duration.max)
	{
		auto i = prepareWait(tok);
		return resolveWait(i, timeout);
	}

private:
	void onData(RequestMessageRaw req)
	{
		version (TracePackets)
		{
			import std.algorithm;

			trace("<< ", req.id, ": ", req.method, ": ", req.paramsJson);
		}

		messageQueue.insertBack(req);
	}

	FileReader reader;
	File writer;
	bool stopped;
	DList!RequestMessageRaw messageQueue;

	struct RequestWait
	{
		RequestToken token;
		bool got = false;
		bool handled = false;
		ResponseMessageRaw ret;
	}

	RequestWait[] responseTokens;

	void run()
	{
		assert(reader.isReading, "must start jsonrpc after file reader!");
		while (!stopped && reader.isReading)
		{
			bool gotAnyHeader;
			bool inHeader = true;
			size_t contentLength = 0;
			do // dmd -O has an issue on mscoff where it forgets to emit a cmp here so this would break with while (inHeader)
			{
				string line = reader.yieldLine(&stopped, false);
				if (!reader.isReading)
					stop(); // abort in header

				if (line.length)
					gotAnyHeader = true;

				if (!line.length && gotAnyHeader)
					inHeader = false;
				else if (line.startsWith("Content-Length:"))
					contentLength = line["Content-Length:".length .. $].strip.to!size_t;
			}
			while (inHeader && !stopped);

			if (stopped)
				break;

			if (contentLength <= 0)
			{
				send(ResponseMessage(RequestToken.init, ResponseError(ErrorCode.invalidRequest, "Invalid/no content length specified")));
				continue;
			}

			auto content = cast(const(char)[]) reader.yieldData(contentLength, &stopped, false);
			if (stopped || content is null)
				break;
			assert(content.length == contentLength);
			RequestMessageRaw request;
			RequestMessageRaw[] extraRequests;
			try
			{
				if (content.length && content[0] == '[')
				{
					int count;
					content.visitJsonArray!((item) {
						count++;

						auto res = handleRequestImpl(item);
						if (request == RequestMessageRaw.init)
							request = res;
						else if (res != RequestMessageRaw.init)
							extraRequests ~= res;
					});
					if (count == 0)
						send(ResponseMessage(null, ResponseError(ErrorCode.invalidRequest, "Empty batch request")));
				}
				else if (content.length && content[0] == '{')
				{
					request = handleRequestImpl(content);
				}
				else
				{
					send(ResponseMessage(null, ResponseError(ErrorCode.invalidRequest, "Invalid request type (must be object or array)")));
				}
			}
			catch (Exception e)
			{
				try
				{
					trace(e);
					trace(content);
					auto idx = content.indexOf("\"id\":");
					auto endIdx = content.indexOf(",", idx);
					RequestToken fallback;
					if (!content.startsWith("[") && idx != -1 && endIdx != -1)
						fallback = deserializeJson!RequestToken(content[idx .. endIdx].strip);
					send(ResponseMessage(fallback, ResponseError(ErrorCode.parseError,
						"Parse error: " ~ e.msg)));
				}
				catch (Exception e)
				{
					errorf("Got invalid request '%s'!", content);
					trace(e);
				}
			}

			if (request != RequestMessageRaw.init)
			{
				onData(request);
				Fiber.yield();
			}

			foreach (req; extraRequests)
			{
				onData(request);
				Fiber.yield();
			}
		}
	}

	RequestMessageRaw handleRequestImpl(scope const(char)[] json)
	{
		if (!json.looksLikeJsonObject)
			throw new Exception("malformed request JSON, must be object");
		auto slices = json.parseKeySlices!("id", "result", "error", "method", "params");

		auto id = slices.id;
		if (slices.result.length && slices.method.length
			|| !slices.result.length && !slices.method.length && !slices.error.length)
		{
			ResponseMessage res;
			if (id.length)
				res.id = id.deserializeJson!RequestToken;
			res.error = ResponseError(ErrorCode.invalidRequest, "missing required members or has ambiguous members");
			send(res);
			return RequestMessageRaw.init;
		}

		bool isResponse = false;
		if (id.length)
		{
			auto tok = id.deserializeJson!RequestToken;
			foreach (ref waiting; responseTokens)
			{
				if (!waiting.got && waiting.token == tok)
				{
					waiting.got = true;
					waiting.ret.id = tok;
					auto res = slices.result;
					auto err = slices.error;
					if (res.length)
						waiting.ret.resultJson = res.idup;
					if (err.length)
						waiting.ret.error = err.deserializeJson!ResponseError;
					isResponse = true;
					break;
				}
			}

			if (!isResponse && slices.result.length)
			{
				send(ResponseMessage(tok,
					ResponseError(ErrorCode.invalidRequest, "unknown request response ID")));
				return RequestMessageRaw.init;
			}
		}
		if (!isResponse)
		{
			RequestMessageRaw request;
			if (slices.id.length)
				request.id = slices.id.deserializeJson!RequestToken;
			if (slices.method.length)
				request.method = slices.method.deserializeJson!string;
			if (slices.params.length)
				request.paramsJson = slices.params.idup;

			if (request.paramsJson.length
				&& request.paramsJson.ptr[0] != '['
				&& request.paramsJson.ptr[0] != '{')
			{
				auto err = ResponseError(ErrorCode.invalidParams,
					"`params` MUST be an object (named arguments) or array "
					~ "(positional arguments), other types are not allowed by spec"
				);
				if (request.id.isNone)
					send(ResponseMessage(null, err));
				else
					send(ResponseMessage(RequestToken(request.id.deref), err));
			}
			else
			{
				return request;
			}
		}
		return RequestMessageRaw.init;
	}
}

/// Helper struct to simulate RPC connections with an RPCProcessor.
/// Intended for use with tests, not for real-world use.
struct MockRPC
{
	import std.process;

	enum shortDelay = 10.msecs;

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

		auto rpcInput = newFileReader(rpcPipe.readEnd);
		rpcInput.start();
		scope (exit)
		{
			rpcInput.stop();
			Thread.sleep(shortDelay);
		}

		auto rpc = new RPCProcessor(rpcInput, resultPipe.writeEnd);
		rpc.call();

		cb(rpc);

		rpc.stop();
		if (rpc.state != Fiber.State.TERM)
			rpc.call();
		assert(rpc.state == Fiber.State.TERM);
	}
}

unittest
{
	import served.lsp.protocol;

	MockRPC mockRPC;

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

	void testRPC(void delegate(RPCProcessor rpc) cb)
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
		rpc.call();
		Thread.sleep(shortDelay);
		rpc.call();
		assert(rpc.hasResponse(waitHandle));
		auto res = rpc.resolveWait(waitHandle);
		assert(res.resultJson == `{"capabilities":{}}`);
	});

	// test close after unfinished message (e.g. client crashed)
	testRPC((rpc) {
		rpcPipe.writeEnd.lockingBinaryWriter.put("Content-Length: 5\r\n\r\n");
		rpcPipe.writeEnd.flush();
		rpc.call();
		Thread.sleep(shortDelay);
		rpc.call();
	});
	testRPC((rpc) {
		rpcPipe.writeEnd.lockingBinaryWriter.put("Content-Length: 5\r\n\r\ntrue");
		rpcPipe.writeEnd.flush();
		rpc.call();
		Thread.sleep(shortDelay);
		rpc.call();
	});

	// test unlucky buffering
	testRPC((rpc) {
		void slowIO()
		{
			rpc.call();
			Thread.sleep(shortDelay);
			rpc.call();
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
		rpcPipe.writeEnd.lockingBinaryWriter.put("Content-Length: ");
		rpcPipe.writeEnd.flush();
		slowIO();
		assert(!rpc.hasResponse(waitHandle));
		rpcPipe.writeEnd.lockingBinaryWriter.put(s.length.to!string);
		rpcPipe.writeEnd.flush();
		slowIO();
		assert(!rpc.hasResponse(waitHandle));
		rpcPipe.writeEnd.lockingBinaryWriter.put("\r\n\r\n");
		rpcPipe.writeEnd.flush();
		slowIO();
		assert(!rpc.hasResponse(waitHandle));
		rpcPipe.writeEnd.lockingBinaryWriter.put(s[0 .. $ / 2]);
		rpcPipe.writeEnd.flush();
		slowIO();
		assert(!rpc.hasResponse(waitHandle));
		rpcPipe.writeEnd.lockingBinaryWriter.put(s[$ / 2 .. $]);
		rpcPipe.writeEnd.flush();
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
		rpc.call();
		Thread.sleep(shortDelay);
		rpc.call();
		assert(rpc.hasResponse(waitHandle));
		auto res = rpc.resolveWait(waitHandle);
		assert(res.resultJson == `{"capabilities":{}}`);

		writePacket(`{"jsonrpc":"2.0","id":"sendtest","method":"test","params":{"x":{"a":4}}}`, pair[1], pair[0]);
		rpc.call();
		Thread.sleep(shortDelay);
		rpc.call();
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
		rpc.call();
		Thread.sleep(shortDelay);
		rpc.call();
		assert(rpc.hasResponse(waitHandle));
		auto res = rpc.resolveWait(waitHandle);
		assert(res.resultJson == `{"capabilities":{}}`);

		void errorTest(string send, string recv)
		{
			writePacket(send);
			rpc.call();
			Thread.sleep(shortDelay);
			rpc.call();
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
		rpc.call();
		Thread.sleep(shortDelay);
		rpc.call();
		expectPacket(`{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"missing required members or has ambiguous members"}}`);
		expectPacket(`{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"missing required members or has ambiguous members"}}`);
		expectPacket(`{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"missing required members or has ambiguous members"}}`);
	});
}

/// Utility functions for common LSP methods performing UI things.
struct WindowFunctions
{
	/// The RPC processor to use for sending/receiving
	RPCProcessor rpc;
	private bool safeShowMessage;

	/// Runs window/showMessage which typically shows a notification box, without any buttons or feedback.
	/// Logs the message to stderr too.
	void showMessage(MessageType type, string message)
	{
		if (!safeShowMessage)
			warningf("%s message: %s", type, message);
		rpc.notifyMethod("window/showMessage", ShowMessageParams(type, message));
		safeShowMessage = false;
	}

	/// Runs window/showMessageRequest which typically shows a message box with possible action buttons to click. Returns the action which got clicked or one with null title if it has been dismissed.
	MessageActionItem requestMessage(MessageType type, string message, MessageActionItem[] actions)
	{
		auto res = rpc.sendRequest("window/showMessageRequest",
				ShowMessageRequestParams(type, message, actions.opt));
		if (!res.resultJson.length)
			return MessageActionItem(null);
		return res.resultJson.deserializeJson!MessageActionItem;
	}

	/// ditto
	string requestMessage(MessageType type, string message, string[] actions)
	{
		MessageActionItem[] a = new MessageActionItem[actions.length];
		foreach (i, action; actions)
			a[i] = MessageActionItem(action);
		return requestMessage(type, message, a).title;
	}

	/// Runs a function and shows a UI message on failure and logs the error.
	/// Returns: true if fn was successfully run or false if an exception occured.
	bool runOrMessage(lazy void fn, MessageType type, string message,
			string file = __FILE__, size_t line = __LINE__)
	{
		try
		{
			fn();
			return true;
		}
		catch (Exception e)
		{
			errorf("Error running in %s(%s): %s", file, line, e);
			showMessage(type, message);
			return false;
		}
	}

	/// Calls $(LREF showMessage) with MessageType.error
	/// Also logs the message to stderr in a more readable way.
	void showErrorMessage(string message)
	{
		error("Error message: ", message);
		safeShowMessage = true;
		showMessage(MessageType.error, message);
	}

	/// Calls $(LREF showMessage) with MessageType.warning
	/// Also logs the message to stderr in a more readable way.
	void showWarningMessage(string message)
	{
		warning("Warning message: ", message);
		safeShowMessage = true;
		showMessage(MessageType.warning, message);
	}

	/// Calls $(LREF showMessage) with MessageType.info
	/// Also logs the message to stderr in a more readable way.
	void showInformationMessage(string message)
	{
		info("Info message: ", message);
		safeShowMessage = true;
		showMessage(MessageType.info, message);
	}

	/// Calls $(LREF showMessage) with MessageType.log
	/// Also logs the message to stderr in a more readable way.
	void showLogMessage(string message)
	{
		trace("Log message: ", message);
		safeShowMessage = true;
		showMessage(MessageType.log, message);
	}
}
