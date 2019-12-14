module served.utils.async;

import core.sync.mutex : Mutex;
import core.time : Duration;

import served.utils.fibermanager;

import std.datetime.stopwatch : msecs, StopWatch;
import std.experimental.logger;

__gshared void delegate(void delegate(), int pages, string file, int line) spawnFiberImpl;
__gshared int timeoutID;
__gshared Timeout[] timeouts;
__gshared Mutex timeoutsMutex;

void spawnFiber(void delegate() cb, int pages = 20, string file = __FILE__, int line = __LINE__)
{
	if (spawnFiberImpl)
		spawnFiberImpl(cb, pages, file, line);
	else
		setImmediate(cb);
}

// Called at most 100x per second
void parallelMain()
{
	timeoutsMutex = new Mutex;
	void delegate()[32] callsBuf;
	void delegate()[] calls;
	while (true)
	{
		synchronized (timeoutsMutex)
			foreach_reverse (i, ref timeout; timeouts)
			{
				if (timeout.sw.peek >= timeout.timeout)
				{
					timeout.sw.stop();
					trace("Calling timeout");
					callsBuf[calls.length] = timeout.callback;
					calls = callsBuf[0 .. calls.length + 1];
					if (timeouts.length > 1)
						timeouts[i] = timeouts[$ - 1];
					timeouts.length--;

					if (calls.length >= callsBuf.length)
						break;
				}
			}

		foreach (call; calls)
			call();

		callsBuf[] = null;
		calls = null;
		Fiber.yield();
	}
}

struct Timeout
{
	StopWatch sw;
	Duration timeout;
	void delegate() callback;
	int id;
}

int setTimeout(void delegate() callback, int ms)
{
	return setTimeout(callback, ms.msecs);
}

void setImmediate(void delegate() callback)
{
	setTimeout(callback, 0);
}

int setTimeout(void delegate() callback, Duration timeout)
{
	trace("Setting timeout for ", timeout);
	Timeout to;
	to.timeout = timeout;
	to.callback = callback;
	to.sw.start();
	synchronized (timeoutsMutex)
	{
		to.id = ++timeoutID;
		timeouts ~= to;
	}
	return to.id;
}

void clearTimeout(int id)
{
	synchronized (timeoutsMutex)
		foreach_reverse (i, ref timeout; timeouts)
		{
			if (timeout.id == id)
			{
				timeout.sw.stop();
				if (timeouts.length > 1)
					timeouts[i] = timeouts[$ - 1];
				timeouts.length--;
				return;
			}
		}
}
