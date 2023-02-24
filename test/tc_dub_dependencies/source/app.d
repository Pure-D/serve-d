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
	string dir = buildNormalizedPath(fs.getcwd, "project");
	scope backend = new WorkspaceD();
	backend.addInstance(dir);
	backend.register!DubComponent;

	version (Posix)
		if (fs.exists(expandTilde(`~/.dub/packages/gitcompatibledubpackage-1.0.4/`)))
			fs.rmdirRecurse(expandTilde(`~/.dub/packages/gitcompatibledubpackage-1.0.4/`));

	auto dub = backend.get!DubComponent(dir);

	dub.upgradeAndSelectAll();
	assert(dub.dependencies.length == 0);

	fs.write(buildPath(dir, "dub.sdl"), "name \"project\"\ndependency \"gitcompatibledubpackage\" version=\"1.0.4\"\n");

	assert(dub.dependencies.length == 0);
	dub.updateImportPaths();
	assert(dub.dependencies.length == 1);
	assert(dub.dependencies[0].name == "gitcompatibledubpackage");

	fs.write(buildPath(dir, "dub.sdl"), "name \"project\"\n");

	assert(dub.dependencies.length == 1);
	dub.updateImportPaths();
	assert(dub.dependencies.length == 0);
}
