import std.file;
import std.string;

import workspaced.api;
import workspaced.coms;

void main()
{
	string dir = getcwd;
	scope backend = new WorkspaceD();
	auto instance = backend.addInstance(dir);
	backend.register!FSWorkspaceComponent;

	auto fsworkspace = backend.get!FSWorkspaceComponent(dir);

	assert(instance.importPaths == [getcwd]);
	fsworkspace.addImports(["source"]);
	assert(instance.importPaths == [getcwd, "source"]);
}
