module served.logger;

import core.stdc.stdio;
import core.sync.mutex;
import core.time;

alias FastMonoTime = MonoTimeImpl!(ClockType.coarse);

enum LogLevel
{
	unset,
	all,
	trace,
	info,
	warning,
	error,
	none
}

enum LogVariadicArguments
{
	init
}

nothrow @nogc @safe
{
	shared FastMonoTime logStart;
	shared LogLevel globalLogLevel = LogLevel.all;
	shared const(Mutex) logMutex;
	LogLevel threadLogLevel = LogLevel.unset;

	void resetLogTime() @system
	{
		logStart = FastMonoTime.currTime();
	}

	void log(LogLevel level, string message, LogVariadicArguments end = LogVariadicArguments.init,
			string func = __FUNCTION__, size_t line = __LINE__)
	{
		float time;
		if (threadLogLevel != LogLevel.unset)
		{
			if (level < threadLogLevel)
				return;
			time = cast(float)((FastMonoTime.currTime - logStart).total!"hnsecs" / 10_000_000.0);
		}
		else
		{
			try
			{
				synchronized (logMutex)
				{
					if (level < globalLogLevel)
						return;

					time = cast(float)((FastMonoTime.currTime - logStart).total!"hnsecs" / 10_000_000.0);
				}
			}
			catch (Exception e)
			{
				time = float.nan;
			}
		}

		char[5] levelStr = 0;
		final switch (level)
		{
		case LogLevel.unset:
			levelStr = "unset";
			break;
		case LogLevel.all:
			levelStr = "  all";
			break;
		case LogLevel.trace:
			levelStr = "trace";
			break;
		case LogLevel.info:
			levelStr = " info";
			break;
		case LogLevel.warning:
			levelStr = " warn";
			break;
		case LogLevel.error:
			levelStr = "error";
			break;
		case LogLevel.none:
			levelStr = " none";
			break;
		}

		(() @trusted => fprintf(stderr, "[%.*s] [%9.5f] [%.*s:%d] %.*s\n",
				cast(int) levelStr.length, levelStr.ptr, time, cast(int) func.length,
				func.ptr, line, cast(int) message.length, message.ptr))();
	}

	void trace(string message, LogVariadicArguments end = LogVariadicArguments.init,
			string func = __FUNCTION__, size_t line = __LINE__)
	{
		log(LogLevel.trace, message, end, func, line);
	}

	void info(string message, LogVariadicArguments end = LogVariadicArguments.init,
			string func = __FUNCTION__, size_t line = __LINE__)
	{
		log(LogLevel.info, message, end, func, line);
	}

	void warning(string message, LogVariadicArguments end = LogVariadicArguments.init,
			string func = __FUNCTION__, size_t line = __LINE__)
	{
		log(LogLevel.warning, message, end, func, line);
	}

	void error(string message, LogVariadicArguments end = LogVariadicArguments.init,
			string func = __FUNCTION__, size_t line = __LINE__)
	{
		log(LogLevel.error, message, end, func, line);
	}
}

void trace(Exception message, LogVariadicArguments end = LogVariadicArguments.init,
		string func = __FUNCTION__, size_t line = __LINE__)
{
	log(LogLevel.trace, message.toString(), end, func, line);
}

void info(Exception message, LogVariadicArguments end = LogVariadicArguments.init,
		string func = __FUNCTION__, size_t line = __LINE__)
{
	log(LogLevel.info, message.toString(), end, func, line);
}

void warning(Exception message, LogVariadicArguments end = LogVariadicArguments.init,
		string func = __FUNCTION__, size_t line = __LINE__)
{
	log(LogLevel.warning, message.toString(), end, func, line);
}

void error(Exception message, LogVariadicArguments end = LogVariadicArguments.init,
		string func = __FUNCTION__, size_t line = __LINE__)
{
	log(LogLevel.error, message.toString(), end, func, line);
}

shared static this()
{
	logMutex = new shared const Mutex();
}
