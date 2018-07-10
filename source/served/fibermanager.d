module served.fibermanager;

import core.thread;

import std.algorithm;
import std.range;

import workspaced.api : Future;

struct FiberManager
{
	Fiber[] fibers;

	alias fibers this;

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
			fibers = fibers.remove(i);
	}
}

void joinAll(Fibers...)(Fibers fibers)
{
	FiberManager f;
	Fiber[] converted;
	foreach (fiber; fibers)
	{
		static if (isInputRange!(typeof(fiber)))
		{
			foreach (fib; fiber)
			{
				static if (is(typeof(fib) : Fiber))
					converted ~= fib;
				else static if (is(typeof(fib) : Future!T, T))
					converted ~= new Fiber(&fib.getYield);
				else
					converted ~= new Fiber(fib);
			}
		}
		else
		{
			static if (is(typeof(fiber) : Fiber))
				converted ~= fiber;
			else static if (is(typeof(fiber) : Future!T, T))
				converted ~= new Fiber(&fiber.getYield);
			else
				converted ~= new Fiber(fiber);
		}
	}
	f.fibers = converted;
	while (f.length)
	{
		f.call();
		Fiber.yield();
	}
}
