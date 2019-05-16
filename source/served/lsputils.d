module served.lsputils;

import painlessjson;

import std.format;
import std.json;

import served.jsonrpc;
import served.logger;
import served.protocol;

void log(MessageType type = MessageType.log, Args...)(ref RPCProcessor rpc, Args args)
{
	rpc.send(JSONValue([
				"jsonrpc": JSONValue("2.0"),
				"method": JSONValue("window/logMessage"),
				"params": args.toJSON
			]));
}

WindowFunctions window(ref RPCProcessor rpc)
{
	return WindowFunctions(rpc);
}

struct WindowFunctions
{
	RPCProcessor rpc;
	private bool safeShowMessage;

	void showMessage(MessageType type, string message)
	{
		if (!safeShowMessage)
			warning(format("%s message: %s", type, message));
		rpc.notifyMethod("window/showMessage", ShowMessageParams(type, message).toJSON);
		safeShowMessage = false;
	}

	MessageActionItem requestMessage(MessageType type, string message, MessageActionItem[] actions)
	{
		auto res = rpc.sendRequest("window/showMessageRequest",
				ShowMessageRequestParams(type, message, actions.opt).toJSON);
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

	void runOrMessage(lazy void fn, MessageType type, string message)
	{
		try
		{
			fn();
		}
		catch (Exception e)
		{
			error(e);
			showMessage(type, message);
		}
	}

	void showErrorMessage(string message)
	{
		error("Error message: " ~ message);
		safeShowMessage = true;
		showMessage(MessageType.error, message);
	}

	void showWarningMessage(string message)
	{
		warning("Warning message: " ~ message);
		safeShowMessage = true;
		showMessage(MessageType.warning, message);
	}

	void showInformationMessage(string message)
	{
		info("Info message: " ~ message);
		safeShowMessage = true;
		showMessage(MessageType.info, message);
	}

	void showLogMessage(string message)
	{
		trace("Log message: " ~ message);
		safeShowMessage = true;
		showMessage(MessageType.log, message);
	}

	void logInstall(string message)
	{
		rpc.notifyMethod("coded/logInstall", JSONValue(message));
	}
}
