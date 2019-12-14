module served.io.http_wrap;

import served.http;
import served.types;

import std.json : JSONType;

__gshared bool letEditorDownload;

struct InteractiveDownload
{
	string url;
	string title;
	string output;
}

void downloadFile(string url, string title, string into)
{
	if (letEditorDownload)
	{
		if (rpc.sendRequest("coded/interactiveDownload", InteractiveDownload(url,
				title, into)).result.type != JSONType.true_)
			throw new Exception("The download has failed.");
	}
	else
	{
		downloadFileManual(url, title, into, (msg) {
			rpc.notifyMethod("coded/logInstall", msg);
		});
	}
}
