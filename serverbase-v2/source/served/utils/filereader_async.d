module served.utils.filereader_async;

@safe:

import core.thread : Fiber;
import eventcore.core;
import served.lsp.filereader;
import served.utils.fibermanager;
import std.algorithm : canFind;
import std.conv;
import std.string;

IFileReader asyncStdinReader()
{
	return new EventcoreFileReader(0);
}

class EventcoreFileReader : IFileReader
{
public:
	this(int fd)
	{
		files = eventDriver.files;
		impl = files.adopt(fd);
		initBuffer();
	}

	this(FileFD fd)
	{
		files = eventDriver.files;
		impl = fd;
		initBuffer();
	}

	override ubyte[] yieldLine(bool* whileThisIs = null, bool equalToThis = true) return
	out (line; !line.canFind("\r\n".representation), [cast(const(char)[]) line].to!string)
	{
		assert(readDone, "can't read from EventcoreFileReader in parallel");
		currentTask = Fiber.getThis;

		auto bufferedCrlf = findCrlf;
		if (bufferedCrlf != -1)
		{
			dataEnd = bufferedCrlf;
		}
		else
		{
			error = null;
			readDone = false;

			retry = true;
			while ((whileThisIs is null || *whileThisIs == equalToThis) && !readDone)
			{
				ensureBufferAvailableOrError("read line was too long");
				if (error)
					throw new Exception("failed reading", error);
				if (retry)
				{
					retry = false;
					files.read(impl, -1, buffer[writeIndex .. $], IOMode.once, &readLineCb);
				}

				(() @trusted => Fiber.yield())();
			}

			files.cancelRead(impl);

			if (!readDone)
				return null;
		}

		auto line = buffer[readIndex .. dataEnd];
		readIndex = dataEnd;
		if (line.endsWith("\r\n".representation))
			line.length -= 2;

		return line;
	}

	override ubyte[] yieldData(size_t length, bool* whileThisIs = null, bool equalToThis = true) return
	{
		while (length > buffer.length)
		{
			// this causes subsequent yieldLine to allow longer lines, but meh, not a real issue
			buffer.length += 1024 * 4;
			backbuffer.length += 1024 * 4;
		}

		assert(readDone, "can't read from EventcoreFileReader in parallel");
		currentTask = Fiber.getThis;
		auto endIndex() => readIndex + length;

		if (endIndex > buffer.length)
			swapBuffers();

		{
			error = null;
			readDone = false;
			scope (exit)
				readDone = true;
			retry = true;
			while ((whileThisIs is null || *whileThisIs == equalToThis) && writeIndex < endIndex)
			{
				ensureBufferAvailableOrError("couldn't use full buffer space to receive all data?!");
				if (error)
					throw new Exception("failed reading", error);
				if (retry)
				{
					retry = false;
					files.read(impl, -1, buffer[writeIndex .. endIndex], IOMode.all, &readFullCb);
				}

				(() @trusted => Fiber.yield())();
			}

			files.cancelRead(impl);
		}

		return buffer[readIndex .. readIndex += length];
	}

	bool isReading()
	{
		return !error;
	}

protected:
	final void initBuffer() scope
	{
		buffer = new ubyte[1024 * 12];
		backbuffer = new ubyte[1024 * 12];

		assert(eventDriver.files.isValid(impl), "invalid handle");
	}

	void ensureBufferAvailableOrError(lazy string error) scope
	{
		if (writeIndex == readIndex)
			writeIndex = readIndex = 0;
		else if (writeIndex == buffer.length)
		{
			if (readIndex > 0)
				swapBuffers();
			else
				throw new Exception(error);
		}
	}

	void swapBuffers() scope
	{
		import std.algorithm : swap;

		auto offset = readIndex;
		assert(offset != 0);
		readIndex = 0;
		writeIndex -= offset;

		backbuffer[0 .. writeIndex] = buffer[offset .. writeIndex + offset];
		swap(backbuffer, buffer);
	}

	ptrdiff_t findCrlf() nothrow const pure @nogc scope
	{
		bool gotCr = false;
		foreach (i; readIndex .. writeIndex)
		{
			if (buffer[i] == '\r')
				gotCr = true;
			else if (gotCr && buffer[i] == '\n')
				return i + 1;
			else
				gotCr = false;
		}
		return -1;
	}

	void readLineCb(FileFD fd, IOStatus status, size_t bytesRead) nothrow
	{
		scope (exit)
			fiberManager.wakeFiber(currentTask);

		assert(fd == impl);
		if (status == IOStatus.ok)
		{
			if (!bytesRead)
			{
				retry = true;
				return;
			}

			writeIndex += bytesRead;

			auto crlf = findCrlf();
			if (crlf != -1)
			{
				dataEnd = crlf;
				readDone = true;
			}
			else
			{
				retry = true;
			}
		}
		else
		{
			try
			{
				error = new Exception("Failed to read line from file: "
					~ status.to!string ~ " - " ~ bytesRead.to!string);
			}
			catch (Exception)
			{
				error = new Exception("Failed to read line from file (unable to read status)");
			}
		}
	}

	void readFullCb(FileFD fd, IOStatus status, size_t bytesRead) nothrow
	{
		scope (exit)
			fiberManager.wakeFiber(currentTask);

		assert(fd == impl);
		if (status == IOStatus.ok)
		{
			writeIndex += bytesRead;
			retry = true;
		}
		else
		{
			try
			{
				error = new Exception("IOStatus non-ok while reading into buffer: "
					~ status.to!string);
			}
			catch (Exception)
			{
				error = new Exception("IOStatus non-ok while reading into buffer (unable to read status)");
			}
		}
	}

	EventDriverFiles files;
	Fiber currentTask;
	FileFD impl;
	Exception error;
	ubyte[] buffer, backbuffer;
	size_t writeIndex = 0;
	size_t readIndex = 0;
	size_t dataEnd = 0;
	bool readDone = true;
	bool retry = false;
}
