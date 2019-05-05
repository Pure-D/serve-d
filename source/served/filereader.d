module served.filereader;

import core.thread;
import core.sync.mutex;

import std.algorithm;
import std.experimental.logger;
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
		running = true;
		scope (exit)
			running = false;

		ubyte[1] buffer;
		while (file.isOpen && !file.eof)
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
		running = true;
		scope (exit)
			running = false;

		auto stdin = GetStdHandle(STD_INPUT_HANDLE);
		INPUT_RECORD inputRecord;
		DWORD nbRead;
		ubyte[4096] buffer;
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
	import core.sys.posix.sys.select;
	import core.sys.posix.sys.time;
	import core.sys.posix.sys.types;
	import core.sys.posix.unistd;
	import core.sys.linux.errno : errno, EINTR;

	override void stop()
	{
		stdin.close();
	}

	override void run()
	{
		running = true;
		scope (exit)
			running = false;

		auto stdin = .stdin;

		ubyte[4096] buffer;
		while (stdin.isOpen && !stdin.eof)
		{
			fd_set rfds;
			timeval tv;

			FD_ZERO(&rfds);
			FD_SET(0, &rfds);

			tv.tv_sec = 1;

			auto ret = select(1, &rfds, null, null, &tv);

			if (ret == -1)
			{
				auto err = errno();
				if (err != EINTR)
					errorf("PosixStdinReader error %s in select()", err);
				Thread.sleep(100.usecs);
			}
			else if (ret)
			{
				auto len = read(0, buffer.ptr, buffer.length);
				if (len == -1)
				{
					errorf("PosixStdinReader error %s in read()", errno());
					Thread.sleep(100.usecs);
				}
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

	void startReading()
	{
		running = true;
		start();
	}

	string yieldLine()
	{
		ptrdiff_t index;
		string ret;
		while (running)
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
		while (running)
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
		auto ret = data.dup;
		data = null;
		return ret;
	}

	abstract void stop();

	bool running;

protected:
	abstract void run();

	ubyte[] data;
	Mutex mutex;
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
