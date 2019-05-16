module served.jsonrpc;

import core.thread;
import core.exception;

import std.container : DList, SList;
import std.conv;
import std.format;
import std.json;
import std.stdio;
import std.string;
import std.typecons;

import served.filereader;
import served.protobase;
import served.logger;

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
		if (res.result.type != JSON_TYPE.NULL)
			msg["result"] = res.result;
		if (!res.error.isNull)
		{
			msg["error"] = res.error._toJSON;
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
			error(raw.to!string);
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

	void notifyMethod(string method, JSONValue value)
	{
		RequestMessage req;
		req.method = method;
		req.params = value;
		send(req);
	}

	void sendMethod(string method)
	{
		RequestMessage req;
		req.id = RequestToken.random;
		req.method = method;
		send(req);
	}

	void sendMethod(string method, JSONValue value)
	{
		RequestMessage req;
		req.id = RequestToken.random;
		req.method = method;
		req.params = value;
		send(req);
	}

	ResponseMessage sendRequest(string method, JSONValue value)
	{
		RequestMessage req;
		req.id = RequestToken.random;
		req.method = method;
		req.params = value;
		send(req);
		return awaitResponse(req.id);
	}

	bool hasData()
	{
		return running && !messageQueue.empty;
	}

	RequestMessage poll()
	{
		if (!hasData)
			throw new Exception("No Data");
		auto ret = messageQueue.front;
		messageQueue.removeFront();
		return ret;
	}

	bool running() @property const
	{
		return !stopped;
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
		scope (exit)
			stopped = true;

		while (!stopped && reader.running)
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
			while (inHeader && reader.running && !stopped);
			if (!reader.running || stopped)
				break;

			assert(contentLength > 0);
			auto content = cast(string) reader.yieldData(contentLength);
			assert(content.length == contentLength);
			RequestMessage request;
			bool validRequest = false;
			JSONValue json;
			try
			{
				json = parseJSON(content);
				validRequest = true;
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
					error(format("Got invalid request '%s'!", content));
					trace(e);
				}
				validRequest = false;
			}

			try
			{
				if (validRequest && !handleJson(json))
				{
					onData(RequestMessage(json));
					Fiber.yield();
				}
			}
			catch (JSONException e)
			{
				send(ResponseMessage(RequestToken("id" in json), ResponseError(ErrorCode.invalidParams)));
			}
		}
	}

	/// Returns: true if the request/response was already handled
	bool handleJson(JSONValue json)
	{
		auto id = "id" in json;
		bool alreadyHandled = false;
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
						waiting.ret.error = ResponseError._fromJSON(*err);
					alreadyHandled = true;
					break;
				}
			}
			if ("method" !in json && !alreadyHandled)
			{
				error(text("Ignoring RPC response which we don't have any listener for with id ", tok));
				alreadyHandled = true;
			}
		}
		return alreadyHandled;
	}
}
