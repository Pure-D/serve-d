module served.utils.async;

@safe:

import core.sync.mutex : Mutex;
import core.time : Duration;

import eventcore.core;
public import served.utils.fibermanager;

import std.datetime.stopwatch : msecs, StopWatch;
import std.experimental.logger;

shared int defaultFiberPages = 4;
shared int defaultPageSize = 4096;
shared Mutex fibersMutex;

void spawnFiber(T)(T callback, int pages = -1, string file = __FILE__, int line = __LINE__) nothrow @trusted
{
	if (pages == -1)
		pages = defaultFiberPages;

	try
	{
		synchronized (fibersMutex)
		{
			fiberManager.put(new Fiber(callback, defaultPageSize * pages), file, line);
		}
	}
	catch (Exception e)
	{
		// `synchronized` failed, probably exiting the app right now
	}
}

alias setImmediate = spawnFiber;

public import eventcore.core : TimerID;

TimerID setTimeout(void delegate() callback, int ms)
{
	return setTimeout(callback, ms.msecs);
}

TimerID setTimeout(void delegate() cb, Duration timeout, Duration interval = Duration.zero)
{
	void callback(TimerID id, bool triggered) nothrow @safe
	{
		if (!triggered)
			return;

		if (interval != Duration.zero)
			eventDriver.timers.wait(id, &callback);

		spawnFiber(cb);
	}

	trace("Setting timeout for ", timeout, ", interval ", interval);
	auto id = eventDriver.timers.create();
	eventDriver.timers.wait(id, &callback);
	eventDriver.timers.set(id, timeout, interval);
	return id;
}

TimerID setInterval(void delegate() callback, Duration interval)
{
	return setTimeout(callback, interval, interval);
}

void clearTimeout(TimerID id)
{
	eventDriver.timers.stop(id);
}

alias clearInterval = clearTimeout;

Fiber runThreaded(void delegate() job) @trusted
{
	auto f = new Fiber({
		auto f = Fiber.getThis();
		bool running = true;
		Throwable exception;
		// TODO: use std.parallelism / TaskPool
		auto t = new Thread({
			try
			{
				job();
			}
			catch (Throwable t)
			{
				exception = t;
			}
			finally
			{
				running = false;
				fiberManager.wakeFiber(f);
			}
		});
		t.isDaemon = true;
		t.start();
		while (running)
			Fiber.yield();

		if (exception)
			throw exception;
	});
	fiberManager.put(f);
	return f;
}
