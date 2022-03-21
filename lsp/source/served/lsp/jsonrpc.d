module served.lsp.jsonrpc;

import core.exception;
import core.thread;

import painlessjson;

import std.container : DList, SList;
import std.conv;
import std.experimental.logger;
import std.json;
import std.stdio;
import std.string;
import std.typecons;

import served.lsp.filereader;
import served.lsp.protocol;

import tinyevent;

alias RequestHandler = ResponseMessage delegate(RequestMessage);
alias EventRequestHandler = void delegate(RequestMessage);

/// Fiber which runs in the background, reading from a FileReader, and calling methods when requested over the RPC interface.
class RPCProcessor : Fiber
{
	/// Constructs this RPC processor using a FileReader to read RPC commands from and a std.stdio.File to write RPC commands to.
	/// Creates this fiber with a reasonable fiber size.
	this(FileReader reader, File writer)
	{
		super(&run, 4096 * 8);
		this.reader = reader;
		this.writer = writer;
	}

	/// Instructs the RPC processor to stop at the next IO read instruction.
	void stop()
	{
		stopped = true;
	}

	/// Sends an RPC response or error.
	/// If `id`, `result` or `error` is not given on the response message, they won't be sent.
	/// However according to the RPC specification, `id` must be set in order for this to be a response object.
	/// Otherwise on success `result` must be set or on error `error` must be set.
	/// This also logs the error to stderr if it is given.
	/// Params:
	///   res = the response message to send.
	void send(ResponseMessage res)
	{
		const(char)[][8] buf;
		int len;
		buf[len++] = `{"jsonrpc":"2.0"`;
		if (res.id.hasData)
		{
			buf[len++] = `,"id":`;
			buf[len++] = res.id.toJSON.toString;
		}

		if (!res.result.isNull)
		{
			buf[len++] = `,"result":`;
			buf[len++] = res.result.get.toString;
		}

		if (!res.error.isNull)
		{
			buf[len++] = `,"error":`;
			buf[len++] = res.error.toJSON.toString;
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
		sendRawPacket(req.toJSON.toString);
	}

	/// Sends a raw JSON object to the other RPC side. 
	void send(JSONValue raw)
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
		// Log on client side instead! (vscode setting: "serve-d.trace.server": "verbose")
		//trace(content);
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
		RequestMessage req;
		req.method = method;
		send(req);
	}

	/// Sends a notification with the given `method` name to the other RPC side with the given `value` parameter serialized to JSON.
	void notifyMethod(T)(string method, T value)
	{
		notifyMethod(method, value.toJSON);
	}

	/// ditto
	void notifyMethod(string method, JSONValue value)
	{
		RequestMessage req;
		req.method = method;
		req.params = value;
		send(req);
	}

	/// Sends a request with the given `method` name to the other RPC side without any parameters.
	/// Doesn't handle the response by the other RPC side.
	/// Returns: a RequestToken to use with $(LREF awaitResponse) to get the response. Can be ignored if the response isn't important.
	RequestToken sendMethod(string method)
	{
		RequestMessage req;
		req.id = RequestToken.random;
		req.method = method;
		send(req);
		return req.id;
	}

	/// Sends a request with the given `method` name to the other RPC side with the given `value` parameter serialized to JSON.
	/// Doesn't handle the response by the other RPC side.
	/// Returns: a RequestToken to use with $(LREF awaitResponse) to get the response. Can be ignored if the response isn't important.
	RequestToken sendMethod(T)(string method, T value)
	{
		return sendMethod(method, value.toJSON);
	}

	/// ditto
	RequestToken sendMethod(string method, JSONValue value)
	{
		RequestMessage req;
		req.id = RequestToken.random;
		req.method = method;
		req.params = value;
		send(req);
		return req.id;
	}

	/// Sends a request with the given `method` name to the other RPC side with the given `value` parameter serialized to JSON.
	/// Awaits the response (using yield) and returns once it's there.
	///
	/// This is a small wrapper to call `awaitResponse(sendMethod(method, value))`
	///
	/// Returns: The response deserialized from the RPC.
	ResponseMessage sendRequest(T)(string method, T value)
	{
		return awaitResponse(sendMethod(method, value));
	}

	/// ditto
	ResponseMessage sendRequest(string method, JSONValue value)
	{
		return awaitResponse(sendMethod(method, value));
	}

	/// Calls the `window/logMessage` method with all arguments concatenated together using text()
	/// Params:
	///   type = the $(REF MessageType, served,lsp,protocol) to use as $(REF LogMessageParams, served,lsp,protocol) type
	///   args = the message parts to send
	void log(MessageType type = MessageType.log, Args...)(Args args)
	{
		send(JSONValue([
					"jsonrpc": JSONValue("2.0"),
					"method": JSONValue("window/logMessage"),
					"params": LogMessageParams(type, text(args)).toJSON
				]));
	}

	/// Returns: `true` if there has been any messages been sent to us from the other RPC side, otherwise `false`.
	bool hasData() const @property
	{
		return !messageQueue.empty;
	}

	/// Returns: the first message from the message queue. Removes it from the message queue so it will no longer be processed.
	/// Throws: Exception if $(LREF hasData) is false.
	RequestMessage poll()
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

	/// Waits for a response message to a request from the other RPC side.
	/// If this is called after the response has already been sent and processed by yielding after sending the request, this will yield forever and use up memory.
	/// So it is important, if you are going to await a response, to do it immediately when sending any request.
	ResponseMessage awaitResponse(RequestToken tok)
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
		while (!responseTokens[i].got)
			yield(); // yield until main loop placed a response
		auto res = responseTokens[i].ret;
		responseTokens[i].handled = true; // make memory reusable
		return res;
	}

private:
	void onData(RequestMessage req)
	{
		messageQueue.insertBack(req);
	}

	FileReader reader;
	File writer;
	bool stopped;
	DList!RequestMessage messageQueue;

	struct RequestWait
	{
		RequestToken token;
		bool got = false;
		bool handled = false;
		ResponseMessage ret;
	}

	RequestWait[] responseTokens;

	void run()
	{
		assert(reader.isReading, "must start jsonrpc after file reader!");
		while (!stopped && reader.isReading)
		{
			bool inHeader = true;
			size_t contentLength = 0;
			do // dmd -O has an issue on mscoff where it forgets to emit a cmp here so this would break with while (inHeader)
			{
				string line = reader.yieldLine;
				if (!reader.isReading)
					stop(); // abort in header

				if (!line.length && contentLength > 0)
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

			auto content = cast(string) reader.yieldData(contentLength);
			if (stopped || content is null)
				break;
			assert(content.length == contentLength);
			RequestMessage request;
			RequestMessage[] extraRequests;
			try
			{
				auto json = parseJSON(content);
				if (json.type == JSONType.array)
				{
					auto arr = json.array;
					if (arr.length == 0)
						send(ResponseMessage(RequestToken.init, ResponseError(ErrorCode.invalidRequest, "Empty batch request")));

					foreach (subRequest; arr)
					{
						auto res = handleRequestImpl(subRequest);
						if (request == RequestMessage.init)
							request = res;
						else if (res != RequestMessage.init)
							extraRequests ~= res;
					}
				}
				else if (json.type == JSONType.object)
				{
					request = handleRequestImpl(json);
				}
				else
				{
					send(ResponseMessage(RequestToken.init, ResponseError(ErrorCode.invalidRequest, "Invalid request type (must be object or array)")));
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
						fallback = RequestToken(parseJSON(content[idx .. endIdx].strip));
					send(ResponseMessage(fallback, ResponseError(ErrorCode.parseError)));
				}
				catch (Exception e)
				{
					errorf("Got invalid request '%s'!", content);
					trace(e);
				}
			}

			if (request != RequestMessage.init)
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

	RequestMessage handleRequestImpl(JSONValue json)
	{
		auto id = "id" in json;
		bool isResponse = false;
		if (id)
		{
			auto tok = RequestToken(id);
			foreach (ref waiting; responseTokens)
			{
				if (!waiting.got && waiting.token == tok)
				{
					waiting.got = true;
					waiting.ret.id = tok;
					auto res = "result" in json;
					auto err = "error" in json;
					if (res)
						waiting.ret.result = *res;
					if (err)
						waiting.ret.error = (*err).fromJSON!ResponseError;
					isResponse = true;
					break;
				}
			}
		}
		if (!isResponse)
		{
			RequestMessage request = RequestMessage(json);
			if (request.params != JSONValue.init
				&& request.params.type != JSONType.object
				&& request.params.type != JSONType.array)
			{
				send(ResponseMessage(request.id,
					ResponseError(ErrorCode.invalidParams,
						"`params` MUST be an object (named arguments) or array "
						~ "(positional arguments), other types are not allowed by spec"
				)));
			}
			else
			{
				return request;
			}
		}
		return RequestMessage.init;
	}
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
		if (res.result == JSONValue.init)
			return MessageActionItem(null);
		return res.result.fromJSON!MessageActionItem;
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
