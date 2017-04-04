module served.jsonrpc;

import core.thread;
import core.exception;

import painlessjson;

import std.container.dlist;
import std.conv;
import std.experimental.logger;
import std.json;
import std.stdio;
import std.string;
import std.typecons;

import served.protocol;
import served.filereader;

import tinyevent;

alias RequestHandler = ResponseMessage delegate(RequestMessage);
alias EventRequestHandler = void delegate(RequestMessage);

class RPCProcessor : Fiber
{
	this(FileReader reader, File writer)
	{
		super(&run);
		this.reader = reader;
		this.writer = writer;
	}

	void stop()
	{
		stopped = true;
	}

	void send(ResponseMessage res)
	{
		auto msg = JSONValue(["jsonrpc" : JSONValue("2.0")]);
		if (res.id.hasData)
			msg["id"] = res.id.toJSON;
		if (res.result.type != JSON_TYPE.NULL)
			msg["result"] = res.result;
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
			stderr.writeln(raw);
			throw new Exception("Sent objects must have a jsonrpc");
		}
		const content = raw.toString();
		string data = "Content-Length: " ~ content.length.to!string ~ "\r\n\r\n" ~ content;
		writer.write(data);
		writer.flush();
	}

	void log(MessageType type = MessageType.log, Args...)(Args args)
	{
		send(JSONValue(["jsonrpc" : JSONValue("2.0"), "method"
				: JSONValue("window/logMessage"), "params" : args.toJSON]));
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

private:
	void onData(RequestMessage req)
	{
		messageQueue.insertBack(req);
	}

	FileReader reader;
	File writer;
	bool stopped;
	DList!RequestMessage messageQueue;

	void run()
	{
		while (!stopped)
		{
			bool inHeader = true;
			size_t contentLength = 0;
			while (inHeader)
			{
				string line = reader.yieldLine;
				if (line == "")
					inHeader = false;
				else if (line.startsWith("Content-Length:"))
					contentLength = line["Content-Length:".length .. $].strip.to!size_t;
			}
			auto content = cast(string) reader.yieldData(contentLength);
			assert(content.length == contentLength);
			RequestMessage request;
			bool validRequest = false;
			try
			{
				request = RequestMessage(parseJSON(content));
				validRequest = true;
			}
			catch (Exception e)
			{
				auto idx = content.indexOf("\"id\":");
				auto endIdx = content.indexOf(",", idx);
				JSONValue fallback;
				if (idx != -1 && endIdx != -1)
					fallback = parseJSON(content[idx .. endIdx].strip);
				else
					fallback = JSONValue(0);
				send(ResponseMessage(RequestToken(&fallback), ResponseError(ErrorCode.parseError)));
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
		RequestMessage req;
		req.method = "window/showMessage";
		req.params = ShowMessageParams(type, message).toJSON;
		rpc.send(req);
		safeShowMessage = false;
	}

	void runOrMessage(lazy void fn, MessageType type, string message)
	{
		try
		{
			fn();
		}
		catch (Exception e)
		{
			stderr.writeln(e);
			showMessage(type, message);
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
