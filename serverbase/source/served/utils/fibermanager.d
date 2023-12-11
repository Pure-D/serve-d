module served.utils.fibermanager;

// debug = Fibers;

import core.thread;
import core.time;

import std.algorithm;
import std.experimental.logger;
import std.range;

import served.utils.memory;

public import core.thread : Fiber, Thread;

struct FiberManager
{
	static struct FiberInfo
	{
		string name;
		Fiber fiber;
		MonoTime queueTime, startTime, endTime;
		Duration timeSpent;
		int numSteps = 0;
		FiberManager* nested; /// for `joinAll` calls

		alias fiber this;
	}

	static FiberManager* currentFiberManager;

	ref FiberInfo currentFiber()
	{
		assert(currentFiberIndex != -1, "not inside a fiber in this FiberManager right now!");
		return fibers[currentFiberIndex];
	}

	const(FiberInfo[]) fiberInfos() const
	{
		return fibers;
	}

	private size_t currentFiberIndex = -1;
	private FiberInfo[] fibers;

	FiberInfo[128] recentlyEnded;
	size_t recentlyEndedIndex;

	void call()
	{
		auto previousFiberManager = currentFiberManager;
		currentFiberManager = &this;
		scope (exit)
			currentFiberManager = previousFiberManager;

		MonoTime now;
		size_t[] toRemove;
		foreach (i, ref fiber; fibers)
		{
			if (fiber.state == Fiber.State.TERM)
				toRemove ~= i;
			else
			{
				currentFiberIndex = i;
				scope (exit)
					currentFiberIndex = -1;
				now = MonoTime.currTime;
				if (fiber.numSteps == 0)
					fiber.startTime = now;
				fiber.call();
				auto now2 = MonoTime.currTime;
				fiber.numSteps++;
				fiber.timeSpent += (now2 - now);
				now = now2;
			}
		}

		if (toRemove.length && now is MonoTime.init)
			now = MonoTime.currTime;

		foreach_reverse (i; toRemove)
		{
			debug (Fibers)
				tracef("Releasing fiber %s", cast(void*) fibers[i]);
			auto rei = recentlyEndedIndex++;
			if (recentlyEndedIndex >= recentlyEnded.length)
				recentlyEndedIndex = 0;
			if (recentlyEnded[rei] !is FiberInfo.init)
				destroyUnset(recentlyEnded[rei].fiber);
			move(fibers[i], recentlyEnded[rei]);
			recentlyEnded[rei].endTime = now;
			fibers = fibers.remove(i);
		}
	}

	size_t length() const @property
	{
		return fibers.length;
	}

	/// Makes a fiber call alongside other fibers with this manager. This transfers the full memory ownership to the manager.
	/// Fibers should no longer be accessed when terminating.
	void put(string name, Fiber fiber, string file = __FILE__, int line = __LINE__)
	{
		debug (Fibers)
			tracef("Putting fiber %s in %s:%s", cast(void*) fiber, file, line);
		fibers.assumeSafeAppend ~= FiberInfo(name, fiber, MonoTime.currTime);
	}
}

private template hasInputRanges(Args...)
{
	static if (Args.length == 0)
		enum hasInputRanges = false;
	else static if (isInputRange!(Args[$ - 1]))
		enum hasInputRanges = true;
	else
		enum hasInputRanges = hasInputRanges!(Args[0 .. $ - 1]);
}

// ridiculously high fiber size (192 KiB per fiber to create), but for parsing big files this is needed to not segfault in libdparse
void joinAll(size_t fiberSize = 4096 * 48, string caller = __FUNCTION__, Fibers...)(Fibers fibers)
{
	import std.conv : to;

	FiberManager f;
	enum anyInputRanges = hasInputRanges!Fibers;
	auto now = MonoTime.currTime;
	static if (anyInputRanges)
	{
		FiberManager.FiberInfo[] converted;
		converted.reserve(Fibers.length);
		void addFiber(string name, Fiber fiber)
		{
			converted ~= FiberManager.FiberInfo(name, fiber, now);
		}
	}
	else
	{
		int convertedIndex;
		FiberManager.FiberInfo[Fibers.length] converted;

		void addFiber(string name, Fiber fiber)
		{
			converted[convertedIndex++] = FiberManager.FiberInfo(name, fiber, now);
		}
	}

	static foreach (i, fiber; fibers)
	{{
		static immutable fiberName = caller ~ ".joinAll[" ~ i.stringof ~ "]";

		static if (isInputRange!(typeof(fiber)))
		{
			foreach (j, fib; fiber)
			{
				string subName = fiberName ~ "[" ~ j.to!string ~ "]";
				static if (is(typeof(fib) : Fiber))
					addFiber(subName, fib);
				else static if (__traits(hasMember, fib, "toFiber"))
					addFiber(subName, fib.toFiber);
				else static if (__traits(hasMember, fib, "getYield"))
					addFiber(subName, new Fiber(&fib.getYield, fiberSize));
				else
					addFiber(subName, new Fiber(fib, fiberSize));
			}
		}
		else
		{
			static if (is(typeof(fiber) : Fiber))
				addFiber(fiberName, fiber);
			else static if (__traits(hasMember, fiber, "toFiber"))
				addFiber(fiberName, fiber.toFiber);
			else static if (__traits(hasMember, fiber, "getYield"))
				addFiber(fiberName, new Fiber(&fiber.getYield, fiberSize));
			else
				addFiber(fiberName, new Fiber(fiber, fiberSize));
		}
	}}

	FiberManager.currentFiberManager.currentFiber.nested = &f;
	scope (exit)
		FiberManager.currentFiberManager.currentFiber.nested = null;

	f.fibers = converted[];
	while (f.length)
	{
		f.call();
		Fiber.yield();
	}
}
