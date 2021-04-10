module served.utils.fibermanager;

// debug = Fibers;

import core.thread;

import std.algorithm;
import std.experimental.logger;
import std.range;

import served.utils.memory;

version (Have_workspace_d)
{
	import workspaced.api : Future;

	enum hasFuture = true;
}
else
	enum hasFuture = false;

public import core.thread : Fiber, Thread;

struct FiberManager
{
	private Fiber[] fibers;

	void call()
	{
		size_t[] toRemove;
		foreach (i, fiber; fibers)
		{
			if (fiber.state == Fiber.State.TERM)
				toRemove ~= i;
			else
				fiber.call();
		}
		foreach_reverse (i; toRemove)
		{
			debug (Fibers)
				tracef("Releasing fiber %s", cast(void*) fibers[i]);
			destroyUnset(fibers[i]);
			fibers = fibers.remove(i);
		}
	}

	size_t length() const @property
	{
		return fibers.length;
	}

	/// Makes a fiber call alongside other fibers with this manager. This transfers the full memory ownership to the manager.
	/// Fibers should no longer be accessed when terminating.
	void put(Fiber fiber, string file = __FILE__, int line = __LINE__)
	{
		debug (Fibers)
			tracef("Putting fiber %s in %s:%s", cast(void*) fiber, file, line);
		fibers.assumeSafeAppend ~= fiber;
	}

	/// ditto
	void opOpAssign(string op : "~")(Fiber fiber, string file = __FILE__, int line = __LINE__)
	{
		put(fiber, file, line);
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
void joinAll(size_t fiberSize = 4096 * 48, Fibers...)(Fibers fibers)
{
	FiberManager f;
	enum anyInputRanges = hasInputRanges!Fibers;
	static if (anyInputRanges)
	{
		Fiber[] converted;
		converted.reserve(Fibers.length);
		void addFiber(Fiber fiber)
		{
			converted ~= fiber;
		}
	}
	else
	{
		int i;
		Fiber[Fibers.length] converted;

		void addFiber(Fiber fiber)
		{
			converted[i++] = fiber;
		}
	}

	foreach (fiber; fibers)
	{
		static if (isInputRange!(typeof(fiber)))
		{
			foreach (fib; fiber)
			{
				static if (is(typeof(fib) : Fiber))
					addFiber(fib);
				else static if (hasFuture && is(typeof(fib) : Future!T, T))
					addFiber(new Fiber(&fib.getYield, fiberSize));
				else
					addFiber(new Fiber(fib, fiberSize));
			}
		}
		else
		{
			static if (is(typeof(fiber) : Fiber))
				addFiber(fiber);
			else static if (hasFuture && is(typeof(fiber) : Future!T, T))
				addFiber(new Fiber(&fiber.getYield, fiberSize));
			else
				addFiber(new Fiber(fiber, fiberSize));
		}
	}
	f.fibers = converted[];
	while (f.length)
	{
		f.call();
		Fiber.yield();
	}
}
