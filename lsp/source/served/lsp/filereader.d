module served.lsp.filereader;

import core.thread;
import core.sync.mutex;

import std.algorithm;
import std.stdio;

/// A file reader implementation using the Win32 API using events. Reads as much
/// content as possible when new data is available at once, making the file
/// reading operation much more efficient when large chunks of data are being
/// transmitted.
version (Windows) class WindowsStdinReader : FileReader
{
	import core.sys.windows.windows;

	this()
	{
		super();
	}

	override void stop()
	{
		wantStop = true;
		closeEvent.wait(5.seconds);
	}

	override void run()
	{
		closeEvent.reset();
		scope (exit)
			closeEvent.set();

		auto stdin = GetStdHandle(STD_INPUT_HANDLE);
		INPUT_RECORD inputRecord;
		DWORD nbRead;
		ubyte[4096] buffer;

		while (!wantStop)
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

	override bool isReading()
	{
		return isRunning;
	}

	private bool wantStop;
	private Event closeEvent;
}

/// A file reader implementation using the POSIX select API using events. Reads
/// as much content as possible when new data is available at once, making the
/// file reading operation much more efficient when large chunks of data are
/// being transmitted.
///
/// This is buggy because it calls `fd.close()` while a `select` is running on
/// it, which causes undefined behavior. Effectively on Linux this would break
/// with multiple file readers running at the same time. (as it could be done in
/// the unittests if not closed properly) There is an `Event` struct used within
/// `stop()` which avoids breakage through reassigned file descriptors.
///
/// Ideally would want to implement Epoll and Kqueue implementations of this
/// reader instead.
version (Posix) class BuggyPosixStdinReader : BuggyPosixFileReader
{
	this()
	{
		File f;
		f.fdopen(0); // use stdin even if std.stdio.stdin is changed
		super(f);
	}
}

/// ditto
version (Posix) class BuggyPosixFileReader : FileReader
{
	import core.stdc.errno;
	import core.sys.posix.sys.select;
	import core.sys.posix.sys.time;
	import core.sys.posix.sys.types;
	import core.sys.posix.unistd;
	import core.sync.event;

	File stdFile;
	Event closeEvent;

	this(File stdFile)
	{
		this.stdFile = stdFile;
		this.closeEvent = Event(true, true);
	}

	override void stop()
	{
		stdFile.close();
		closeEvent.wait(5.seconds);
	}

	override void run()
	{
		closeEvent.reset();
		scope (exit)
			closeEvent.set();
		int fd = stdFile.fileno;

		ubyte[4096] buffer;
		scope (exit)
			stdFile.close();

		while (true)
		{
			fd_set rfds;
			timeval tv;

			FD_ZERO(&rfds);
			FD_SET(fd, &rfds);

			tv.tv_sec = 1;

			auto ret = select(fd + 1, &rfds, null, null, &tv);

			if (ret == -1)
			{
				int err = errno;
				if (err == EINTR)
					continue;
				stderr.writeln("[fatal] BuggyPosixStdinReader error ", err, " in select()");
				break;
			}
			else if (ret)
			{
				auto len = read(fd, buffer.ptr, buffer.length);
				if (len == -1)
				{
					int err = errno;
					if (err == EINTR)
						continue;
					stderr.writeln("BuggyPosixStdinReader error ", errno, " in read()");
					break;
				}
				else if (len == 0)
				{
					break; // eof
				}
				else
				{
					synchronized (mutex)
						data ~= buffer[0 .. len];
				}
			}
		}
	}

	override bool isReading()
	{
		return isRunning && !stdin.eof && !stdin.error;
	}
}

/// Base class for file readers which can read a file or standard handle line
/// by line in a Fiber context, yielding until a line is available.
abstract class FileReader : Thread
{
	this()
	{
		super(&run);
		isDaemon = true;
		mutex = new Mutex();
	}

	string yieldLine(bool* whileThisIs = null, bool equalToThis = true)
	{
		ptrdiff_t index;
		string ret;
		while (whileThisIs is null || *whileThisIs == equalToThis)
		{
			bool hasData;
			synchronized (mutex)
			{
				index = data.countUntil([cast(ubyte) '\r', cast(ubyte) '\n']);
				if (index != -1)
				{
					ret = cast(string) data[0 .. index].dup;
					data = data[index + 2 .. $];
					break;
				}

				hasData = data.length != 0;
			}

			if (!hasData && !isReading)
				return ret.length ? ret : null;

			Fiber.yield();
		}
		return ret;
	}

	/// Yields until the specified length of data is available, then removes the
	/// data from the incoming data stream atomically and returns a duplicate of
	/// it.
	/// Returns null if the file reader stops while reading.
	ubyte[] yieldData(size_t length, bool* whileThisIs = null, bool equalToThis = true)
	{
		while (whileThisIs is null || *whileThisIs == equalToThis)
		{
			bool hasData;
			synchronized (mutex)
			{
				if (data.length >= length)
				{
					auto ret = data[0 .. length].dup;
					data = data[length .. $];
					return ret;
				}

				hasData = data.length != 0;
			}

			if (!hasData && !isReading)
				return null;

			Fiber.yield();
		}
		return null;
	}

	abstract void stop();
	abstract bool isReading();

protected:
	abstract void run();

	ubyte[] data;
	Mutex mutex;
}

/// Creates a new FileReader using the GC reading from stdin using a platform
/// optimized implementation or StdFileReader if none is available.
///
/// The created instance can then be started using the `start` method and
/// stopped at exit using the `stop` method.
///
/// Examples:
/// ---
/// auto input = newStdinReader();
/// input.start();
/// scope (exit)
///     input.stop();
/// ---
FileReader newStdinReader()
{
	version (Windows)
		return new WindowsStdinReader();
	else version (Posix)
		return new BuggyPosixStdinReader();
	else
		static assert(false, "no stdin reader for this platform implemented");
}

/// ditto
FileReader newFileReader(File stdFile)
{
	version (Posix)
		return new BuggyPosixFileReader(stdFile);
	else
		static assert(false, "no generic file reader for this platform implemented");
}

/// Reads a file into a given buffer with a specified maximum length. If the
/// file is bigger than the buffer, the buffer will be resized using the GC and
/// updated through the ref argument.
/// Params:
///   file = The filename of the file to read.
///   buffer = A GC allocated buffer that may be enlarged if it is too small.
///   maxLen = The maxmimum amount of bytes to read from the file.
/// Returns: The contents of the file up to maxLen or EOF. The data is a slice
/// of the buffer argument case to a `char[]`.
char[] readCodeWithBuffer(string file, scope return ref ubyte[] buffer, size_t maxLen = 1024 * 50)
in (buffer.length > 0)
{
	auto f = File(file, "rb");
	size_t len;
	while (len < buffer.length)
	{
		len += f.rawRead(buffer[len .. $]).length;
		if (f.eof)
			return cast(char[]) buffer[0 .. min(maxLen, len)];
	}
	while (buffer.length * 2 < maxLen)
	{
		buffer.length *= 2;
		while (len < buffer.length)
		{
			len += f.rawRead(buffer[len .. $]).length;
			if (f.eof)
				return cast(char[]) buffer[0 .. min(maxLen, len)];
		}
	}
	if (buffer.length >= maxLen)
		return cast(char[]) buffer[0 .. maxLen];
	buffer.length = maxLen;
	f.rawRead(buffer[len .. $]);
	return cast(char[]) buffer;
}

unittest
{
	ubyte[2048] buffer;
	auto slice = buffer[];
	assert(slice.ptr is buffer.ptr);
	auto code = readCodeWithBuffer("lsp/source/served/lsp/filereader.d", slice);
	assert(slice.ptr !is buffer.ptr);
	assert(code[0 .. 29] == "module served.lsp.filereader;");

	slice = new ubyte[1024 * 64]; // enough to store full file
	code = readCodeWithBuffer("lsp/source/served/lsp/filereader.d", slice);
	assert(code[0 .. 29] == "module served.lsp.filereader;");

	// with max length
	code = readCodeWithBuffer("lsp/source/served/lsp/filereader.d", slice, 16);
	assert(code == "module served.ls");

	// with max length and small buffer
	slice = new ubyte[8];
	code = readCodeWithBuffer("lsp/source/served/lsp/filereader.d", slice, 16);
	assert(code == "module served.ls");

	// small buffer not aligning
	slice = new ubyte[7];
	code = readCodeWithBuffer("lsp/source/served/lsp/filereader.d", slice, 16);
	assert(code == "module served.ls");
}
