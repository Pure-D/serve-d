module served.lsp.filereader;

import core.sync.condition;
import core.sync.mutex;
import core.thread;
import core.time : Duration;

import std.algorithm;
import std.stdio;

/// A file reader implementation using the Win32 API using events. Reads as much
/// content as possible when new data is available at once, making the file
/// reading operation much more efficient when large chunks of data are being
/// transmitted.
version (Windows) class WindowsStdinReader : FileReader
{
	import core.sync.event;
	import core.sys.windows.windows;

	this()
	{
		super();
	}

	override void stop()
	{
		wantStop = true;
		CancelSynchronousIo(thread);
		closeEvent.wait(5.seconds);
	}

	override void run()
	{
		closeEvent.reset();
		scope (exit)
			closeEvent.set();
		// let a waiter notice we stopped instead of sitting out its timeout
		scope (exit)
			synchronized (mutex)
				notifyDataAvailable();

		auto stdin = GetStdHandle(STD_INPUT_HANDLE);
		ubyte[4096] buffer;

		thread = GetCurrentThread();

		while (!wantStop)
		{
			DWORD len;

			if (!ReadFile(stdin, &buffer, buffer.length, &len, null))
			{
				auto error = GetLastError();

				if (error == ERROR_OPERATION_ABORTED)
					continue;

				stderr.writeln("ReadFile failed ", error);
				return;
			}

			if (len == 0)
			{
				stderr.writeln("WindowsStdinReader EOF");
				return;
			}

			synchronized (mutex)
			{
				data ~= buffer[0 .. len];
				notifyDataAvailable();
			}
		}
	}

	override bool isReading()
	{
		return isRunning;
	}

private:
	bool wantStop;
	Event closeEvent;
	HANDLE thread;
}

version (Windows)
{
	private extern(Windows) bool CancelSynchronousIo(void* hThread);
}


/// ditto
version (Windows) class WindowsFileReader : FileReader
{
	import core.sync.event;
	import core.sys.windows.windows;

	this(File file)
	{
		handle = file.windowsHandle;
		super();
	}

	override void stop()
	{
		wantStop = true;
		CancelSynchronousIo(thread);
		closeEvent.wait(5.seconds);
	}

	override void run()
	{
		closeEvent.reset();
		scope (exit)
			closeEvent.set();
		// let a waiter notice we stopped instead of sitting out its timeout
		scope (exit)
			synchronized (mutex)
				notifyDataAvailable();

		ubyte[4096] buffer;

		thread = GetCurrentThread();
		int errorCount = 0;

		while (!wantStop)
		{
			DWORD numRead;
			if (!ReadFile(handle, buffer.ptr, buffer.length, &numRead, null))
			{
				auto error = GetLastError();
				if (error == ERROR_OPERATION_ABORTED)
					continue;
				stderr.writeln("WindowsStdinReader failed with ", error);
				errorCount++;
				if (errorCount > 10)
				{
					stderr.writeln("Closing WindowsStdinReader because too many errors");
					break;
				}
				continue;
			}
			synchronized (mutex)
			{
				data ~= buffer[0 .. numRead];
				notifyDataAvailable();
			}
		}
	}

	override bool isReading()
	{
		return isRunning;
	}

	private bool wantStop;
	private Event closeEvent;
	private HANDLE handle;
	private HANDLE thread;
}

/// A file reader implementation using the POSIX select API using events. Reads
/// as much content as possible when new data is available at once, making the
/// file reading operation much more efficient when large chunks of data are
/// being transmitted.
///
/// Ideally would want to implement Epoll and Kqueue implementations of this
/// reader instead, to support much longer timeouts with proper stop methods.
version (Posix) class PosixStdinReader : PosixFileReader
{
	this()
	{
		File f;
		f.fdopen(0); // use stdin even if std.stdio.stdin is changed
		super(f);
	}
}

/// ditto
version (Posix) class PosixFileReader : FileReader
{
	import core.stdc.errno;
	import core.sync.event;
	import core.sys.posix.sys.select;
	import core.sys.posix.sys.time;
	import core.sys.posix.sys.types;
	import core.sys.posix.unistd;

	File stdFile;
	Event closeEvent;
	bool wantStop;

	this(File stdFile)
	{
		this.stdFile = stdFile;
		this.closeEvent = Event(true, true);
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
			closeEvent.setIfInitialized();
		// let a waiter notice we stopped instead of sitting out its timeout
		scope (exit)
			synchronized (mutex)
				notifyDataAvailable();
		int fd = stdFile.fileno;

		ubyte[4096] buffer;
		scope (exit)
			stdFile.close();

		wantStop = false;
		while (!wantStop)
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
				stderr.writeln("[fatal] PosixStdinReader error ", err, " in select()");
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
					stderr.writeln("PosixStdinReader error ", errno, " in read()");
					break;
				}
				else if (len == 0)
				{
					break; // eof
				}
				else
				{
					synchronized (mutex)
					{
						data ~= buffer[0 .. len];
						notifyDataAvailable();
					}
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
		dataAvailable = new Condition(mutex);
	}

	/// Blocks until data is appended or `timeout` elapses.
	/// Returns: false without waiting when data is already buffered, so a caller
	/// driving a loop can tell it must not treat this as a completed wait.
	bool waitForData(Duration timeout)
	{
		synchronized (mutex)
		{
			if (data.length)
				return false;
			dataAvailable.wait(timeout);
			return true;
		}
	}

	/// Wakes `waitForData`. Call while holding `mutex`.
	protected void notifyDataAvailable()
	{
		dataAvailable.notifyAll();
	}

	string yieldLine(bool* whileThisIs = null, bool equalToThis = true)
	{
		// hoisted: as a literal this allocates on every call, and this runs once
		// per main loop iteration even when idle
		static immutable ubyte[2] crlf = [cast(ubyte) '\r', cast(ubyte) '\n'];

		ptrdiff_t index;
		string ret;
		while (whileThisIs is null || *whileThisIs == equalToThis)
		{
			bool hasData;
			synchronized (mutex)
			{
				index = data.countUntil(crlf[]);
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
	Condition dataAvailable;
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
		return new PosixStdinReader();
	else
		static assert(false, "no stdin reader for this platform implemented");
}

/// ditto
FileReader newFileReader(File stdFile)
{
	version (Windows)
		return new WindowsFileReader(stdFile);
	else version (Posix)
		return new PosixFileReader(stdFile);
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

unittest
{
	import core.time : msecs, seconds;
	import std.datetime.stopwatch : AutoStart, StopWatch;

	// concrete reader that never reads anything, so `data` is driven by the test
	static class TestReader : FileReader
	{
		override void stop() {}
		override bool isReading() { return true; }
		protected override void run() {}

		void append(ubyte[] bytes)
		{
			synchronized (mutex)
			{
				data ~= bytes;
				notifyDataAvailable();
			}
		}
	}

	auto reader = new TestReader();

	// nothing buffered: waits, and reports that it waited
	auto sw = StopWatch(AutoStart.yes);
	assert(reader.waitForData(50.msecs));
	assert(sw.peek >= 40.msecs);

	// data already buffered: must return false *without* waiting, otherwise a
	// caller skipping its sleep on the strength of this call would spin
	reader.append(cast(ubyte[]) "Content-Length: 99\r\n\r\npartial".dup);
	sw = StopWatch(AutoStart.yes);
	assert(!reader.waitForData(5.seconds));
	assert(sw.peek < 1.seconds);

	// appending wakes a waiter well before the timeout
	auto empty = new TestReader();
	auto waker = new Thread({
		Thread.sleep(30.msecs);
		empty.append(cast(ubyte[]) "x".dup);
	});
	waker.start();
	sw = StopWatch(AutoStart.yes);
	assert(empty.waitForData(5.seconds));
	assert(sw.peek < 2.seconds);
	waker.join();
}
