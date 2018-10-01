module served.filereader;

import core.thread;
import core.sync.mutex;

import std.algorithm;
import std.stdio;

class FileReader : Thread
{
	this(File file)
	{
		super(&run);
		mutex = new Mutex();
		this.file = file;
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

	void stop()
	{
		file.close();
	}

private:
	void run()
	{
		foreach (b; file.byChunk(1))
			synchronized (mutex)
				data ~= b[0];
	}

	ubyte[] data;
	File file;
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
