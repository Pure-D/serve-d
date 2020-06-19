module served.utils.trace;

import core.time;
import std.stdio : File;

struct TraceDataStat(T)
{
	T min;
	T max;
	T total;

	void resetTo(T value)
	{
		min = value;
		max = value;
		total = value;
	}

	void put(T value)
	{
		if (value < min)
			min = value;
		if (value > max)
			max = value;
		total += value;
	}

	auto map(alias fn)()
	{
		import std.functional : unaryFun;

		alias mapFun = unaryFun!fn;

		auto minV = mapFun(min);
		auto maxV = mapFun(max);
		auto totalV = mapFun(total);

		return TraceDataStat!(typeof(minV))(minV, maxV, totalV);
	}
}

struct TraceState
{
	MonoTime time;
	long gc;

	static TraceState current()
	{
		import core.memory : GC;

		TraceState ret;
		ret.time = MonoTime.currTime;
		ret.gc = GC.stats().allocatedInCurrentThread;
		return ret;
	}
}

struct TraceData
{
	TraceDataStat!long gcUsage;
	TraceDataStat!Duration runtime;
	int timesCalled;

	TraceState start()
	{
		return TraceState.current();
	}

	void end(TraceState state)
	{
		auto now = TraceState.current();
		if (timesCalled == 0)
		{
			gcUsage.resetTo(now.gc - state.gc);
			runtime.resetTo(now.time - state.time);
		}
		else
		{
			gcUsage.put(now.gc - state.gc);
			runtime.put(now.time - state.time);
		}
		timesCalled++;
	}
}

TraceData*[string] _traceInfos;

/// CTFE function to generate mixin code for function tracing
/// The trace
const(char)[] traceStatistics(const(char)[] name)
{
	import std.ascii : isAlphaNum;

	char[] id;
	foreach (char c; name)
		if (c.isAlphaNum)
			id ~= c;
	//dfmt off
	return `
		static bool _trace_init_` ~ id ~ ` = false;
		static TraceData _trace_info_` ~ id ~ `;
		if (!_trace_init_` ~ id ~ `)
		{
			_traceInfos["` ~ name ~ `"] = &_trace_info_` ~ id ~ `;
			_trace_init_` ~ id ~ ` = true;
		}
		auto _trace_state_` ~ id ~ ` = _trace_info_` ~ id ~ `.start();

		scope (exit)
		{
			_trace_info_` ~ id ~ `.end(_trace_state_` ~ id ~ `);
		}
	`;
	//dfmt on
}

void dumpTraceInfos(File output)
{
	import std.array : array;
	import std.algorithm : sort;

	output.write("trace name\tnum calls");
	foreach (stat; ["time", "gc"])
		output.writef("\tmin %s\tmax %s\ttotal %s\tavg %s",
				stat, stat, stat, stat);
	output.writeln();

	auto kv = _traceInfos.byKeyValue.array
		.sort!"a.value.timesCalled > b.value.timesCalled";

	foreach (entry; kv)
	{
		int total = entry.value.timesCalled;
		double dTotal = cast(double)total;

		void dumpStat(T)(TraceDataStat!T stat)
		{
			output.write('\t', stat.min);
			output.write('\t', stat.max);
			output.write('\t', stat.total);
			output.write('\t', stat.total / dTotal);
		}

		output.write(entry.key, '\t', total);
		dumpStat(entry.value.runtime.map!"a.total!`msecs`");
		dumpStat(entry.value.gcUsage);
		output.writeln();
	}
}
