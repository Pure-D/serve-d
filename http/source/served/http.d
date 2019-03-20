module served.http;

import core.thread : Fiber;

import fs = std.file;
import std.conv;
import std.datetime.stopwatch;
import std.exception;
import std.format;
import std.json;
import std.math;
import std.path;
import std.random;
import std.stdio;
import std.string;
import std.traits;

import requests;

version (Windows) pragma(lib, "wininet");

struct InteractiveDownload
{
	string url;
	string title;
	string output;
}

void downloadFileManual(string url, string title, string into, void delegate(string) onLog)
{
	File file = File(into, "wb");

	StopWatch sw;
	sw.start();

	version (Windows)
	{
		import core.sys.windows.windows : DWORD;
		import core.sys.windows.wininet : INTERNET_FLAG_NO_UI,
			INTERNET_OPEN_TYPE_PRECONFIG, InternetCloseHandle, InternetOpenA,
			InternetOpenUrlA, InternetReadFile, IRF_NO_WAIT, INTERNET_BUFFERSA,
			HttpQueryInfoA, HTTP_QUERY_CONTENT_LENGTH;

		auto handle = enforce(InternetOpenA("serve-d_release-downloader/Pure-D/serve-d",
				INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0), "Failed to open internet handle");
		scope (exit)
			InternetCloseHandle(handle);

		auto obj = enforce(InternetOpenUrlA(handle, cast(const(char)*) url.toStringz,
				null, 0, INTERNET_FLAG_NO_UI, 0), "Opening URL failed");
		scope (exit)
			InternetCloseHandle(obj);

		scope ubyte[] buffer = new ubyte[50 * 1024];

		long maxLen;
		DWORD contentLengthLength = 16;
		DWORD index = 0;
		if (HttpQueryInfoA(obj, HTTP_QUERY_CONTENT_LENGTH, buffer.ptr, &contentLengthLength, &index))
			maxLen = (cast(char[]) buffer[0 .. contentLengthLength]).strip.to!long;

		long received;
		while (true)
		{
			DWORD read;
			if (!InternetReadFile(obj, buffer.ptr, cast(DWORD) buffer.length, &read))
				throw new Exception("Failed to read from internet file");

			if (read == 0)
				break;

			file.rawWrite(buffer[0 .. read]);
			received += read;

			if (sw.peek >= 1.seconds)
			{
				sw.reset();
				if (maxLen > 0)
					onLog(format!"%s %s / %s (%.1f %%)"(title, humanSize(received),
							humanSize(maxLen), received / cast(float) maxLen * 100));
				else
					onLog(format!"%s %s / ???"(title, humanSize(received)));
				Fiber.yield();
			}
		}
	}
	else
	{
		auto req = Request();
		req.useStreaming = true;

		auto res = req.get(url);

		foreach (part; res.receiveAsRange())
		{
			file.rawWrite(part);

			if (sw.peek >= 1.seconds)
			{
				sw.reset();
				onLog(format!"%s %s / %s (%.1f %%)"(title, humanSize(res.contentReceived),
						humanSize(res.contentLength), res.contentReceived / cast(float) res.contentLength * 100));
				Fiber.yield();
			}
		}
	}
}

string humanSize(T)(T bytes) if (isIntegral!T)
{
	static immutable string prefixes = "kMGTPE";

	if (bytes < 1024)
		return text(bytes, " B");
	int exp = cast(int)(log2(bytes) / 8); // 8 = log2(1024)
	return format!"%.1f %siB"(bytes / cast(float) pow(1024, exp), prefixes[exp - 1]);
}
