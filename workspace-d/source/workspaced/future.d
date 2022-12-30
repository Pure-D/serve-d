module workspaced.future;

import core.time;

import std.algorithm;
import std.parallelism;
import std.traits : isCallable, isCopyable;

class Future(T)
{
	import core.thread : Fiber, Thread;

	static if (!is(T == void))
		private T value;
	Throwable exception;
	bool has;
	void delegate() _onDone;
	private Thread _worker;

	/// Sets the onDone callback if no value has been set yet or calls immediately if the value has already been set or was set during setting the callback.
	/// Crashes with an assert error if attempting to override an existing callback (i.e. calling this function on the same object twice).
	void onDone(void delegate() callback) @property
	{
		assert(!_onDone);
		if (has)
			callback();
		else
		{
			bool called;
			_onDone = { called = true; callback(); };
			if (has && !called)
				callback();
		}
	}

	static if (is(T == void))
		static Future!void finished()
		{
			auto ret = new typeof(return);
			ret.has = true;
			return ret;
		}
	else
		static Future!T fromResult(T value)
		{
			auto ret = new typeof(return);
			ret.value = move(value);
			ret.has = true;
			return ret;
		}

	static Future!T async(T delegate() cb)
	{
		auto ret = new typeof(return);
		ret._worker = new Thread({
			try
			{
				static if (is(T == void))
				{
					cb();
					ret.finish();
				}
				else
					ret.finish(cb());
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		}).start();
		return ret;
	}

	static Future!T fromError(Throwable error)
	{
		auto ret = new typeof(return);
		ret.error = error;
		ret.has = true;
		return ret;
	}

	static if (is(T == void))
		void finish()
		{
			assert(!has);
			has = true;
			if (_onDone)
				_onDone();
		}
	else
		void finish(T value)
		{
			assert(!has);
			this.value = move(value);
			has = true;
			if (_onDone)
				_onDone();
		}

	void error(Throwable t)
	{
		assert(!has);
		exception = t;
		has = true;
		if (_onDone)
			_onDone();
	}

	/// Waits for the result of this future using Thread.sleep
	T getBlockingImpl(bool moveValue, alias sleepDur = 1.msecs)()
	{
		while (!has)
			Thread.sleep(sleepDur);
		if (_worker)
		{
			_worker.join();
			_worker = null;
		}
		if (exception)
			throw exception;
		static if (!is(T == void))
		{
			static if (moveValue)
				return move(value);
			else
				return value;
		}
	}

	/// ditto
	static if (is(T == void) || isCopyable!T)
		alias getBlocking(alias sleepDur = 1.msecs) = getBlockingImpl!(false, sleepDur);

	/// ditto
	static if (!is(T == void))
		alias moveBlocking(alias sleepDur = 1.msecs) = getBlockingImpl!(true, sleepDur);

	/// Waits for the result of this future using Fiber.yield
	T getYieldImpl(bool moveValue)()
	{
		assert(Fiber.getThis() !is null,
			"Attempted to getYield without being in a Fiber context");

		while (!has)
			Fiber.yield();
		if (_worker)
		{
			_worker.join();
			_worker = null;
		}
		if (exception)
			throw exception;
		static if (!is(T == void))
		{
			static if (moveValue)
				return move(value);
			else
				return value;
		}
	}

	/// ditto
	static if (is(T == void) || isCopyable!T)
		alias getYield = getYieldImpl!false;

	/// ditto
	static if (!is(T == void))
		alias moveYield = getYieldImpl!true;
		
	/// Waits for the result of this future using Fiber.yield
	T getImmediatelyImpl(bool moveValue)()
	{
		assert(has,
			"Attempted to getImmediately without data being ready");

		if (_worker)
		{
			_worker.join();
			_worker = null;
		}
		if (exception)
			throw exception;
		static if (!is(T == void))
		{
			static if (moveValue)
				return move(value);
			else
				return value;
		}
	}

	/// ditto
	static if (is(T == void) || isCopyable!T)
		alias getImmediately = getImmediatelyImpl!false;

	/// ditto
	static if (!is(T == void))
		alias moveImmediately = getImmediatelyImpl!true;
}

static void whenAllDone(T)(Future!T[] futs, void delegate() callback)
{
	if (!futs.length)
		return callback();

	size_t i = 0;
	void onDone()
	{
		while (i < futs.length && futs[i].has)
			i++;

		if (i == futs.length)
			callback();
		else
			futs[i].onDone(&onDone);
	}
	futs[0].onDone(&onDone);
}

enum string gthreadsAsyncProxy(string call) = `auto __futureRet = new typeof(return);
	gthreads.create({
		mixin(traceTask);
		try
		{
			__futureRet.finish(` ~ call ~ `);
		}
		catch (Throwable t)
		{
			__futureRet.error(t);
		}
	});
	return __futureRet;
`;

void create(T)(TaskPool pool, T fun) if (isCallable!T)
{
	pool.put(task(fun));
}
