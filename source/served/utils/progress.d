module served.utils.progress;

import std.format;
import core.time : MonoTime;

import served.types;

/// Documents a progress type should have progress attached
private enum withProgress;

/// Documents a progress type can possibly have some progress attached
private enum optionalProgress;

/// The types to report
enum ProgressType
{
	/// default invalid/ignored value
	unknown,
	/// sent when serve-d is first registering all workspace-d components. Sent on first configLoad.
	globalStartup,
	/// sent before each workspace that is going to be loaded. Sent for every workspace.
	/// sent with workspaceUri argument
	@optionalProgress configLoad,
	/// sent when all workspaces have been loaded. Sent when everything is initialized.
	configFinish,
	/// sent for each root of a workspace on startup. Sent for every configLoad for all roots.
	/// sent with root.uri argument
	@withProgress workspaceStartup,
	/// sent for every auto completion server starting up. Sent after all workspaceStartups for a workspace.
	/// sent with root.uri argument
	@withProgress completionStartup,
	/// sent when dub is being reloaded
	/// sent with instance.uri argument
	@withProgress dubReload,
	/// sent when the import paths are being indexed
	/// sent with instance.uri argument
	@withProgress importReload,
	/// sent when dub is being upgraded before imports are being reloading
	/// sent with instance.uri argument
	@withProgress importUpgrades,
}

__gshared MonoTime startupTime;

shared static this()
{
	startupTime = MonoTime.currTime();
}

void reportProgress(Args...)(bool condition, ProgressType type, size_t step, size_t max, Args args)
{
	if (condition)
		reportProgress(type, step, max, args);
}

void reportProgress(Args...)(ProgressType type, size_t step, size_t max, Args args)
{
	double time = (MonoTime.currTime() - startupTime).total!"msecs" / 1000.0;
	if (max > 0)
		rpc.log(format!"[progress] [%09.3f] [%s] %d / %d: "(time, type, step, max), args);
	else if (step > 0)
		rpc.log(format!"[progress] [%09.3f] [%s] %d: "(time, type, step), args);
	else if (Args.length > 0)
		rpc.log(format!"[progress] [%09.3f] [%s]: "(time, type), args);
	else
		rpc.log(format!"[progress] [%09.3f] [%s]"(time, type));
}
