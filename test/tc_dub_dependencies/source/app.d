module app;

import std.conv : to;
import fs = std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;

import workspaced.api;
import workspaced.com.dub;

void main()
{
	{
		import std.logger;
		globalLogLevel = LogLevel.trace;
		static if (__VERSION__ < 2101)
			sharedLog = new FileLogger(stderr);
		else
			sharedLog = (() @trusted => cast(shared) new FileLogger(stderr))();
	}

	string dir = buildNormalizedPath(fs.getcwd, "project");

	fs.write(buildPath(dir, "dub.sdl"), "name \"project\"\n");

	scope backend = new WorkspaceD();
	backend.addInstance(dir);
	backend.register!DubComponent;

	import dub.internal.logging : LogLevel, setLogLevel;
	setLogLevel(LogLevel.debug_);

	version (Posix)
	{
		if (fs.exists(expandTilde(`~/.dub/packages/gitcompatibledubpackage-1.0.4/`)))
			fs.rmdirRecurse(expandTilde(`~/.dub/packages/gitcompatibledubpackage-1.0.4/`));
		if (fs.exists(expandTilde(`~/.dub/packages/gitcompatibledubpackage/1.0.4/`)))
			fs.rmdirRecurse(expandTilde(`~/.dub/packages/gitcompatibledubpackage/1.0.4/`));
	}

	auto dub = backend.get!DubComponent(dir);

	assert(dub.rootDependencies.length == 0);
	dub.selectAndDownloadMissing();
	assert(dub.rootDependencies.length == 0);

	fs.write(buildPath(dir, "dub.sdl"), "name \"project\"\ndependency \"gitcompatibledubpackage\" version=\"1.0.4\"\n");

	dub.updateImportPaths();
	assert(dub.missingDependencies.length == 1);
	assert(dub.rootDependencies.length == 1);
	dub.selectAndDownloadMissing();
	assert(dub.missingDependencies.length == 0);
	assert(dub.rootDependencies.length == 1);
	assert(dub.rootDependencies[0] == "gitcompatibledubpackage");

	fs.write(buildPath(dir, "dub.sdl"), "name \"project\"\n");

	assert(dub.rootDependencies.length == 1);
	dub.updateImportPaths();
	assert(dub.rootDependencies.length == 0);
}
