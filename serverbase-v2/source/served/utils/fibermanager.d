module served.utils.fibermanager;

@safe:

// debug = Fibers;

import core.atomic;
import core.thread;

import std.algorithm;
import std.experimental.logger;
import std.range;

import served.lsp.jsonrpc;
import served.utils.memory;

import eventcore.core;

public import core.thread : Fiber, Thread;

shared FiberManager _fiberManager;

shared(FiberManager) fiberManager() @safe nothrow
{
	if (!_fiberManager)
		_fiberManager = new shared FiberManager();
	return _fiberManager;
}

class FiberManager : IFiberManager
{
	enum int GROUP_WAKE = 1 << 0;
	enum int GROUP_RPC_RECV = 1 << 1;
	enum int GROUP_FIBERS_MODIFIED = 1 << 2;

	struct FiberInfo
	{
		Fiber fiber;
		int groups;
	}

	private FiberInfo[] fibers;
	private size_t[] toRemove;
	private int notifyGroups;
	private EventID triggerEvent;
	private bool waiting;
	private bool running;

	private void triggerEventCB(EventID) nothrow
	{
		waiting = false;
	}

	void run() shared @trusted
	{
		triggerEvent = eventDriver.events.create();

		running = true;
		while (running)
		{
			if (!waiting)
			{
				eventDriver.events.wait(triggerEvent, &(cast() this).triggerEventCB);
				waiting = true;
			}

			eventDriver.core.processEvents(20.msecs);
			(cast() this).mainLoopIteration();
		}
	}

	void stop() shared
	{
		running = false;
		eventDriver.events.trigger(triggerEvent, true);
	}

	void mainLoopIteration()
	{
		auto wakeGroups = notifyGroups | GROUP_WAKE;
		notifyGroups = 0;

		foreach (i, ref fiber; fibers)
		{
			bool run;
			if (fiber.groups & wakeGroups)
			{
				fiber.groups &= ~wakeGroups;
				run = true;
			}
			if (run)
				(() @trusted => fiber.fiber.call())();
			if (fiber.fiber.state == Fiber.State.TERM)
				toRemove ~= i;
		}

		if (toRemove.length)
		{
			notifyGroups |= GROUP_FIBERS_MODIFIED;
			foreach_reverse (i; toRemove)
				fibers = remove!(SwapStrategy.unstable)(fibers, i);
			toRemove.length = 0;
			(() @trusted {
				toRemove = toRemove.assumeSafeAppend;
				fibers = fibers.assumeSafeAppend;
			})();
		}
	}

	void resumeListeners() shared
	{
		notifyGroups.atomicOp!"|="(GROUP_RPC_RECV);
		eventDriver.events.trigger(triggerEvent, true);
	}

	void setCurrentAsListener() shared
	{
		addCurrentToGroup(GROUP_RPC_RECV);
	}

	void addFiberToGroup(Fiber id, int group) shared nothrow @trusted
	{
		foreach (ref fiber; cast() fibers)
		{
			if (cast() fiber.fiber is id)
			{
				fiber.groups.atomicOp!"|="(group);
				return;
			}
		}
		assert(false, "fiber is not managed");
	}

	void* resumeCurrentAfter(Duration time) shared
	{
		auto task = Fiber.getThis();
		if (time <= Duration.zero)
		{
			wakeFiber(task);
			return null;
		}

		TimerID ret = eventDriver.timers.create();
		eventDriver.timers.wait(ret, (tid, fired) { if (fired) wakeFiber(task); });
		eventDriver.timers.set(ret, time, Duration.zero);

		static if ((void*).sizeof <= TimerID.sizeof)
			return (() @trusted => *cast(void**) &ret)();
		else
			static assert(false, "TimerID too large on this platform, TODO: implement moving it onto the heap and return it here");
	}

	void cancelResumeAfter(void* handle) shared @trusted
	{
		if (handle is null)
			return;

		static if ((void*).sizeof <= TimerID.sizeof)
			eventDriver.timers.stop(*cast(TimerID*) &handle);
		else
			eventDriver.timers.stop(*cast(TimerID*) handle);
	}

	void wakeFiber(Fiber fiber) nothrow shared
	{
		addFiberToGroup(fiber, FiberManager.GROUP_WAKE);
		eventDriver.events.trigger(triggerEvent, true);
	}

	void addCurrentToGroup(int group) shared
	{
		addFiberToGroup(Fiber.getThis, group);
	}

	/// Makes a fiber call alongside other fibers with this manager. This transfers the full memory ownership to the manager.
	/// Fibers should no longer be accessed when terminating.
	void put(Fiber fiber, string file = __FILE__, int line = __LINE__) nothrow shared @trusted
	{
		debug (Fibers)
			tracef("Putting fiber %s in %s:%s", cast(void*) fiber, file, line);

		if (fiber.state == Fiber.State.TERM)
			return;

		fibers ~= shared FiberInfo(cast(shared) fiber, GROUP_WAKE);
	}

	/// ditto
	void opOpAssign(string op : "~")(Fiber fiber, string file = __FILE__, int line = __LINE__) nothrow shared
	{
		put(fiber, file, line);
	}

	// TODO: shared fibers / worker tasks that run in different threads
	alias joinAllThreaded = joinAll;

	// ridiculously high fiber size (192 KiB per fiber to create), but for parsing big files this is needed to not segfault in libdparse
	void joinAll(size_t fiberSize = 4096 * 48, Fibers...)(scope Fibers fibers) @trusted shared
	{
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
					else static if (__traits(hasMember, fib, "toFiber"))
						addFiber(fib.toFiber);
					else
						addFiber(new Fiber(fib, fiberSize));
				}
			}
			else
			{
				static if (is(typeof(fiber) : Fiber))
					addFiber(fiber);
				else static if (__traits(hasMember, fiber, "toFiber"))
					addFiber(fiber.toFiber);
				else
					addFiber(new Fiber(fiber, fiberSize));
			}
		}
		foreach (f; converted)
			put(f);

		bool allDone = false;
		while (!allDone)
		{
			allDone = true;
			foreach (f; converted)
				if (f.state != Fiber.State.TERM)
				{
					allDone = false;
					addCurrentToGroup(GROUP_FIBERS_MODIFIED);
					Fiber.yield();
					break;
				}
		}
	}

	alias parallel = parallelImpl!false;
	alias parallelThreaded = parallelImpl!true;

	template parallelImpl(bool threaded)
	{
		auto parallelImpl(Range)(Range r) return shared
		{
			import std.range : ElementType;

			static struct JoiningRange
			{
				shared FiberManager fiberManager;
				Range r;

				int opApply(scope int delegate(ref ElementType!Range n) dg)
				{
					static if (threaded)
						fiberManager.joinAllThreaded(r.map!(e => dg(e)));
					else
						fiberManager.joinAll(r.map!(e => () { dg(e); }));
					return 0;
				}
			}

			return JoiningRange(this, r);
		}
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

void joinAllThreaded(size_t fiberSize = 4096 * 48, Fibers...)(scope Fibers fibers) @trusted
{
	import core.lifetime;

	return fiberManager.joinAllThreaded!(fiberSize, Fibers)(forward!fibers);
}

// ridiculously high fiber size (192 KiB per fiber to create), but for parsing big files this is needed to not segfault in libdparse
void joinAll(size_t fiberSize = 4096 * 48, Fibers...)(scope Fibers fibers) @trusted
{
	import core.lifetime;

	return fiberManager.joinAll!(fiberSize, Fibers)(forward!fibers);
}

void await(Fiber f) @trusted
{
	while (f.state != Fiber.State.TERM)
	{
		fiberManager.addCurrentToGroup(FiberManager.GROUP_FIBERS_MODIFIED);
		Fiber.yield();
	}
}

void await(Duration d)
{
	import std.datetime.stopwatch;

	StopWatch sw;
	sw.start();

	fiberManager.resumeCurrentAfter(d);
	while (sw.peek < d)
		(() @trusted => Fiber.yield())();
}
