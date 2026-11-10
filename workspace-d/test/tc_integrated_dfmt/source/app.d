import std.file;
import std.string;

import workspaced.api;
import workspaced.coms;

void main()
{
	string dir = getcwd;
	scope backend = new WorkspaceD();
	backend.register!DfmtComponent;

	auto dfmt = backend.get!DfmtComponent;
	assert(dfmt.format("void main(){}").getBlocking.splitLines.length > 1);
}
