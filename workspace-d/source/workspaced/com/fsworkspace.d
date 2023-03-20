module workspaced.com.fsworkspace;

import std.json;
import workspaced.api;

@component("fsworkspace")
@instancedOnly
class FSWorkspaceComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		if (!refInstance)
			throw new Exception("fsworkspace requires to be instanced");

		paths = instance.cwd ~ config.get!(string[])("fsworkspace", "additionalPaths");
		importPathProvider = &imports;
		stringImportPathProvider = &imports;
		importFilesProvider = &imports;
	}

	/// Adds new import paths to the workspace. You can add import paths, string import paths or file paths.
	void addImports(string[] values)
	{
		paths ~= values;
	}

	/// Lists all import-, string import- & file import paths
	string[] imports() nothrow
	{
		return paths;
	}

private:
	string[] paths;
}
