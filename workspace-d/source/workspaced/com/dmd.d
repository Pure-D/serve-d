module workspaced.com.dmd;

import core.thread;
import std.array;
import std.datetime;
import std.datetime.stopwatch : StopWatch;
import std.file;
import std.json;
import std.path;
import std.process;
import std.random;

import painlessjson;

import workspaced.api;

@component("dmd")
class DMDComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	/// Tries to compile a snippet of code with the import paths in the current directory. The arguments `-c -o-` are implicit.
	/// The sync function may be used to prevent other measures from running while this is running.
	/// Params:
	///   cb = async callback
	///   code = small code snippet to try to compile
	///   dmdArguments = additional arguments to pass to dmd before file name
	///   count = how often to compile (duration is divided by either this or less in case timeout is reached)
	///   timeoutMsecs = when to abort compilation after, note that this will not abort mid-compilation but not do another iteration if this timeout has been reached.
	/// Returns: [DMDMeasureReturn] containing logs from only the first compilation pass
	Future!DMDMeasureReturn measure(scope const(char)[] code,
			string[] dmdArguments = [], int count = 1, int timeoutMsecs = 5000)
	{
		return typeof(return).async(() => measureSync(code, dmdArguments, count, timeoutMsecs));
	}

	/// ditto
	DMDMeasureReturn measureSync(scope const(char)[] code,
			string[] dmdArguments = [], int count = 1, int timeoutMsecs = 5000)
	{
		dmdArguments ~= ["-c", "-o-"];
		DMDMeasureReturn ret;

		auto timeout = timeoutMsecs.msecs;

		StopWatch sw;

		int effective;

		foreach (i; 0 .. count)
		{
			if (sw.peek >= timeout)
				break;
			string[] baseArgs = [path];
			foreach (path; importPaths)
				baseArgs ~= "-I=" ~ path;
			foreach (path; stringImportPaths)
				baseArgs ~= "-J=" ~ path;
			auto pipes = pipeProcess(baseArgs ~ dmdArguments ~ "-",
					Redirect.stderrToStdout | Redirect.stdout | Redirect.stdin, null,
					Config.none, instance.cwd);
			pipes.stdin.write(code);
			pipes.stdin.close();
			if (i == 0)
			{
				if (count == 0)
					sw.start();
				ret.log = pipes.stdout.byLineCopy().array;
				auto status = pipes.pid.wait();
				if (count == 0)
					sw.stop();
				ret.success = status == 0;
				ret.crash = status < 0;
			}
			else
			{
				if (count < 10 || i != 1)
					sw.start();
				pipes.pid.wait();
				if (count < 10 || i != 1)
					sw.stop();
				pipes.stdout.close();
				effective++;
			}
			if (!ret.success)
				break;
		}

		ret.duration = sw.peek;

		if (effective > 0)
			ret.duration = ret.duration / effective;

		return ret;
	}

	string path() @property @ignoredFunc const
	{
		return config.get("dmd", "path", "dmd");
	}
}

///
/*
version (DigitalMars) unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DMDComponent;
	auto measure = backend.get!DMDComponent(workspace.directory)
		.measure("import std.stdio;", null, 100).getBlocking;
	assert(measure.success);
	assert(measure.duration < 5.seconds);
}
*/

///
struct DMDMeasureReturn
{
	/// true if dmd returned 0
	bool success;
	/// true if an ICE occured (segfault / negative return code)
	bool crash;
	/// compilation output
	string[] log;
	/// how long compilation took (serialized to msecs float in json)
	Duration duration;

	/// Converts a json object to [DMDMeasureReturn]
	static DMDMeasureReturn fromJSON(JSONValue value)
	{
		DMDMeasureReturn ret;
		if (auto success = "success" in value)
			ret.success = success.type == JSONType.true_;
		if (auto crash = "crash" in value)
			ret.crash = crash.type == JSONType.true_;
		if (auto log = "log" in value)
			ret.log = (*log).fromJSON!(string[]);
		if (auto duration = "duration" in value)
			ret.duration = (cast(long)(duration.floating * 10_000)).hnsecs;
		return ret;
	}

	/// Converts this object to a [JSONValue]
	JSONValue toJSON() const
	{
		//dfmt off
		return JSONValue([
			"success": JSONValue(success),
			"crash": JSONValue(crash),
			"log": log.toJSON,
			"duration": JSONValue(duration.total!"hnsecs" / cast(double) 10_000)
		]);
		//dfmt on
	}
}
