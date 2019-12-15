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

class RPCProcessor : Fiber
{
	this(FileReader reader, File writer)
	{
		super(&run, 4096 * 8);
		this.reader = reader;
		this.writer = writer;
	}

	void stop()
	{
		stopped = true;
	}

	void send(ResponseMessage res)
	{
		auto msg = JSONValue(["jsonrpc": JSONValue("2.0")]);
		if (res.id.hasData)
			msg["id"] = res.id.toJSON;

		if (!res.result.isNull)
			msg["result"] = res.result.get;

		if (!res.error.isNull)
		{
			msg["error"] = res.error.toJSON;
			stderr.writeln(msg["error"]);
		}

		send(msg);
	}

	void send(RequestMessage req)
	{
		send(req.toJSON);
	}

	void send(JSONValue raw)
	{
		if (!("jsonrpc" in raw))
		{
			error(raw);
			throw new Exception("Sent objects must have a jsonrpc");
		}
		const content = raw.toString().replace("\\/", "/");
		// Log on client side instead! (vscode setting: "serve-d.trace.server": "verbose")
		//trace(content);
		string data = "Content-Length: " ~ content.length.to!string ~ "\r\n\r\n" ~ content;
		writer.rawWrite(data);
		writer.flush();
	}

	void notifyMethod(string method)
	{
		RequestMessage req;
		req.method = method;
		send(req);
	}

	void notifyMethod(T)(string method, T value)
	{
		RequestMessage req;
		req.method = method;
		req.params = value.toJSON;
		send(req);
	}

	void sendMethod(string method)
	{
		RequestMessage req;
		req.id = RequestToken.random;
		req.method = method;
		send(req);
	}

	void sendMethod(T)(string method, T value)
	{
		RequestMessage req;
		req.id = RequestToken.random;
		req.method = method;
		req.params = value.toJSON;
		send(req);
	}

	ResponseMessage sendRequest(T)(string method, T value)
	{
		RequestMessage req;
		req.id = RequestToken.random;
		req.method = method;
		req.params = value.toJSON;
		send(req);
		return awaitResponse(req.id);
	}

	void log(MessageType type = MessageType.log, Args...)(Args args)
	{
		send(JSONValue([
					"jsonrpc": JSONValue("2.0"),
					"method": JSONValue("window/logMessage"),
					"params": LogMessageParams(type, text(args)).toJSON
				]));
	}

	bool hasData()
	{
		return !messageQueue.empty;
	}

	RequestMessage poll()
	{
		if (!hasData)
			throw new Exception("No Data");
		auto ret = messageQueue.front;
		messageQueue.removeFront();
		return ret;
	}

	bool running = true;

	WindowFunctions window()
	{
		return WindowFunctions(this);
	}

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
		while (!stopped)
		{
			bool inHeader = true;
			size_t contentLength = 0;
			do // dmd -O has an issue on mscoff where it forgets to emit a cmp here so this would break with while (inHeader)
			{
				string line = reader.yieldLine;
				if (!line.length && contentLength > 0)
					inHeader = false;
				else if (line.startsWith("Content-Length:"))
					contentLength = line["Content-Length:".length .. $].strip.to!size_t;
			}
			while (inHeader);
			assert(contentLength > 0);
			auto content = cast(string) reader.yieldData(contentLength);
			assert(content.length == contentLength);
			RequestMessage request;
			bool validRequest = false;
			try
			{
				auto json = parseJSON(content);
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
					request = RequestMessage(json);
					validRequest = true;
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
					JSONValue fallback;
					if (idx != -1 && endIdx != -1)
						fallback = parseJSON(content[idx .. endIdx].strip);
					else
						fallback = JSONValue(0);
					send(ResponseMessage(RequestToken(&fallback), ResponseError(ErrorCode.parseError)));
				}
				catch (Exception e)
				{
					errorf("Got invalid request '%s'!", content);
					trace(e);
				}
			}
			if (validRequest)
			{
				onData(request);
				Fiber.yield();
			}
		}
	}
}

struct WindowFunctions
{
	RPCProcessor rpc;
	private bool safeShowMessage;

	void showMessage(MessageType type, string message)
	{
		if (!safeShowMessage)
			warningf("%s message: %s", type, message);
		rpc.notifyMethod("window/showMessage", ShowMessageParams(type, message));
		safeShowMessage = false;
	}

	MessageActionItem requestMessage(MessageType type, string message, MessageActionItem[] actions)
	{
		auto res = rpc.sendRequest("window/showMessageRequest",
				ShowMessageRequestParams(type, message, actions.opt));
		if (res.result == JSONValue.init)
			return MessageActionItem(null);
		return res.result.fromJSON!MessageActionItem;
	}

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

	void showErrorMessage(string message)
	{
		error("Error message: ", message);
		safeShowMessage = true;
		showMessage(MessageType.error, message);
	}

	void showWarningMessage(string message)
	{
		warning("Warning message: ", message);
		safeShowMessage = true;
		showMessage(MessageType.warning, message);
	}

	void showInformationMessage(string message)
	{
		info("Info message: ", message);
		safeShowMessage = true;
		showMessage(MessageType.info, message);
	}

	void showLogMessage(string message)
	{
		trace("Log message: ", message);
		safeShowMessage = true;
		showMessage(MessageType.log, message);
	}
}
