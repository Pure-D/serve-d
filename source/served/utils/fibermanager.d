module served.utils.fibermanager;

// debug = Fibers;

import core.thread;

import std.algorithm;
import std.experimental.logger;
import std.range;

import served.io.memory;

import workspaced.api : Future;

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

void joinAll(size_t fiberSize = 4096 * 24, Fibers...)(Fibers fibers)
{
	FiberManager f;
	int i;
	Fiber[Fibers.length] converted;
	foreach (fiber; fibers)
	{
		static if (isInputRange!(typeof(fiber)))
		{
			foreach (fib; fiber)
			{
				static if (is(typeof(fib) : Fiber))
					converted[i++] = fib;
				else static if (is(typeof(fib) : Future!T, T))
					converted[i++] = new Fiber(&fib.getYield, fiberSize);
				else
					converted[i++] = new Fiber(fib, fiberSize);
			}
		}
		else
		{
			static if (is(typeof(fiber) : Fiber))
				converted[i++] = fiber;
			else static if (is(typeof(fiber) : Future!T, T))
				converted[i++] = new Fiber(&fiber.getYield, fiberSize);
			else
				converted[i++] = new Fiber(fiber, fiberSize);
		}
	}
	f.fibers = converted[];
	while (f.length)
	{
		f.call();
		Fiber.yield();
	}
}
