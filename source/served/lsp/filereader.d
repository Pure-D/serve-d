module served.lsp.filereader;

import core.thread;
import core.sync.mutex;

import std.algorithm;
import std.stdio;

class StdFileReader : FileReader
{
	this(File file)
	{
		super();
		this.file = file;
	}

	override void stop()
	{
		file.close();
	}

	override void run()
	{
		ubyte[1] buffer;
		while (!file.eof)
		{
			auto chunk = file.rawRead(buffer[]);
			synchronized (mutex)
				data ~= chunk;
		}
	}

	File file;
}

version (Windows) class WindowsStdinReader : FileReader
{
	import core.sys.windows.windows;

	bool running;

	this()
	{
		super();
	}

	override void stop()
	{
		running = false;
	}

	override void run()
	{
		auto stdin = GetStdHandle(STD_INPUT_HANDLE);
		INPUT_RECORD inputRecord;
		DWORD nbRead;
		ubyte[4096] buffer;
		running = true;
		while (running)
		{
			switch (WaitForSingleObject(stdin, 1000))
			{
			case WAIT_TIMEOUT:
				break;
			case WAIT_OBJECT_0:
				DWORD len;
				if (!ReadFile(stdin, &buffer, buffer.length, &len, null))
				{
					stderr.writeln("ReadFile failed ", GetLastError());
					break;
				}
				if (len == 0)
				{
					stderr.writeln("WindowsStdinReader EOF");
					running = false;
					return;
				}
				synchronized (mutex)
					data ~= buffer[0 .. len];
				break;
			case WAIT_FAILED:
				stderr.writeln("stdin read failed ", GetLastError());
				break;
			case WAIT_ABANDONED:
				stderr.writeln("stdin read wait was abandoned ", GetLastError());
				break;
			default:
				stderr.writeln("Unexpected WaitForSingleObject response");
				break;
			}
		}
	}
}

version (Posix) class PosixStdinReader : FileReader
{
	import core.stdc.errno;
	import core.sys.posix.sys.select;
	import core.sys.posix.sys.time;
	import core.sys.posix.sys.types;
	import core.sys.posix.unistd;

	override void stop()
	{
		stdin.close();
	}

	override void run()
	{

		ubyte[4096] buffer;
		while (!stdin.eof)
		{
			fd_set rfds;
			timeval tv;

			FD_ZERO(&rfds);
			FD_SET(0, &rfds);

			tv.tv_sec = 1;

			auto ret = select(1, &rfds, null, null, &tv);

			if (ret == -1)
			{
				int err = errno;
				if (err == EINTR)
					continue;
				stderr.writeln("PosixStdinReader error ", err, " in select()");
			}
			else if (ret)
			{
				auto len = read(0, buffer.ptr, buffer.length);
				if (len == -1)
					stderr.writeln("PosixStdinReader error ", errno, " in read()");
				else
					synchronized (mutex)
						data ~= buffer[0 .. len];
			}
		}
	}
}

abstract class FileReader : Thread
{
	this()
	{
		super(&run);
		mutex = new Mutex();
	}

	string yieldLine()
	{
		ptrdiff_t index;
		string ret;
		while (true)
		{
			synchronized (mutex)
			{
				index = data.countUntil([cast(ubyte) '\r', cast(ubyte) '\n']);
				if (index != -1)
				{
					ret = cast(string) data[0 .. index].dup;
					data = data[index + 2 .. $];
					break;
				}
			}
			Fiber.yield();
		}
		return ret;
	}

	ubyte[] yieldData(size_t length)
	{
		while (true)
		{
			synchronized (mutex)
			{
				if (data.length >= length)
				{
					auto ret = data[0 .. length].dup;
					data = data[length .. $];
					return ret;
				}
			}
			Fiber.yield();
		}
	}

	abstract void stop();

protected:
	abstract void run();

	ubyte[] data;
	Mutex mutex;
	bool running;
}

char[] readCodeWithBuffer(string file, ref ubyte[] buffer, size_t maxLen = 1024 * 50)
{
	auto f = File(file, "rb");
	size_t len = f.rawRead(buffer).length;
	if (f.eof)
		return cast(char[]) buffer[0 .. len];
	while (buffer.length * 2 < maxLen)
	{
		buffer.length *= 2;
		len += f.rawRead(buffer[len .. $]).length;
		if (f.eof)
			return cast(char[]) buffer[0 .. len];
	}
	if (buffer.length >= maxLen)
		return cast(char[]) buffer;
	buffer.length = maxLen;
	f.rawRead(buffer[len .. $]);
	return cast(char[]) buffer;
}
