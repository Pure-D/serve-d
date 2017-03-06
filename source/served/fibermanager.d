module served.fibermanager;

import core.thread;

import std.algorithm;

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
		static if (is(fiber == Fiber))
			converted ~= fiber;
		else
			converted ~= new Fiber(fiber);
	}
	f.fibers = converted;
	while (f.length)
	{
		f.call();
		Fiber.yield();
	}
}
