module crash_handler;

version (linux)
	enum BacktraceHandler = true;
else version (OSX)
	enum BacktraceHandler = true;
else
	enum BacktraceHandler = false;

static if (BacktraceHandler)
{
	extern (C) int backtrace(void** buffer, int size) nothrow @nogc @system;
	extern (C) void backtrace_symbols_fd(const(void*)* buffer, int size, int fd) nothrow @nogc @system;

	extern (C) void backtrace_handler(int sig) nothrow @nogc @system
	{
		import core.sys.posix.stdlib : exit;
		import core.sys.posix.stdio : fprintf, fflush, stderr;

		void*[100] buffer;
		auto size = backtrace(buffer.ptr, cast(int) buffer.length);

		fprintf(stderr, "Error: signal %d:\n", sig);
		backtrace_symbols_fd(buffer.ptr, size, 2);
		fflush(stderr);
		exit(-sig);
	}

	void registerErrorHandlers()
	{
		import core.sys.posix.stdio : fprintf, stderr;
		import core.sys.posix.signal : signal, SIGABRT, SIGALRM, SIGILL, SIGINT,
			SIGKILL, SIGPIPE, SIGSEGV, SIGTRAP;

		static foreach (sig; [
				SIGABRT, SIGALRM, SIGILL, SIGINT, SIGKILL, SIGPIPE, SIGSEGV, SIGTRAP
			])
			signal(sig, &backtrace_handler);

		// this is print on every invocation of serve-d, so we only print this in unittests and assume it works elsewhere
		version (unittest)
			fprintf(stderr, "Registered backtrace signal handlers\n");
	}

	shared static this()
	{
		registerErrorHandlers();
	}
}
