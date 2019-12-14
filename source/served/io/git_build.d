module served.io.git_build;

import served.types;

import std.conv : to;
import std.path : buildPath;
import std.string : join;

import rm.rf;

import fs = std.file;

bool compileDependency(string cwd, string name, string gitURI, string[][] commands)
{
	import std.process : pipe, spawnProcess, Config, tryWait, wait;

	int run(string[] cmd, string cwd)
	{
		import core.thread : Thread, Fiber;

		rpc.notifyMethod("coded/logInstall", "> " ~ cmd.join(" "));
		auto stdin = pipe();
		auto stdout = pipe();
		auto pid = spawnProcess(cmd, stdin.readEnd, stdout.writeEnd,
				stdout.writeEnd, null, Config.none, cwd);
		stdin.writeEnd.close();
		size_t i;
		string[] lines;
		bool done;
		new Thread({
			scope (exit)
				done = true;
			foreach (line; stdout.readEnd.byLine)
				lines ~= line.idup;
		}).start();
		while (!pid.tryWait().terminated || !done || i < lines.length)
		{
			if (i < lines.length)
			{
				rpc.notifyMethod("coded/logInstall", lines[i++]);
			}
			Fiber.yield();
		}
		return pid.wait;
	}

	rpc.notifyMethod("coded/logInstall", "Installing into " ~ cwd);
	try
	{
		auto newCwd = buildPath(cwd, name);
		if (fs.exists(newCwd))
		{
			rpc.notifyMethod("coded/logInstall", "Deleting old installation from " ~ newCwd);
			try
			{
				rmdirRecurseForce(newCwd);
			}
			catch (Exception)
			{
				rpc.notifyMethod("coded/logInstall", "WARNING: Failed to delete " ~ newCwd);
			}
		}
		auto ret = run([
				firstConfig.git.userPath, "clone", "--recursive", "--depth=1", gitURI,
				name
				], cwd);
		if (ret != 0)
			throw new Exception("git ended with error code " ~ ret.to!string);
		foreach (command; commands)
			run(command, newCwd);
		return true;
	}
	catch (Exception e)
	{
		rpc.notifyMethod("coded/logInstall", "Failed to install " ~ name);
		rpc.notifyMethod("coded/logInstall", e.toString);
		return false;
	}
}
