import std.file;
import std.stdio;
import std.path;

import workspaced.api;
import workspaced.coms;
import workspaced.com.dscanner;

enum mainLine = __LINE__ + 1;
void main()
{
	string dir = getcwd;
	scope backend = new WorkspaceD();
	auto instance = backend.addInstance(dir);

	backend.register!DscannerComponent;
	auto dscanner = backend.get!DscannerComponent(dir);

	auto issues = dscanner.lint("", "dscanner.ini",
			"void main() { int unused = 0; } void undocumented() { }");
	assert(issues.length >= 3);
	auto defs = dscanner.listDefinitions("app.d", import("app.d"))
		.definitions;
	assert(defs.length == 2);
	assert(defs[0].name == "mainLine");
	assert(defs[0].line == mainLine - 1);
	assert(defs[0].type == 'v');

	assert(defs[1].name == "main");
	assert(defs[1].line == mainLine);
	assert(defs[1].type == 'f');
	assert(defs[1].attributes.length >= 1);
	assert(defs[1].attributes["signature"] == "()");

	backend.register!FSWorkspaceComponent;
	auto fsworkspace = backend.get!FSWorkspaceComponent(dir);

	fsworkspace.addImports(["source"]);
	assert(dscanner.findSymbol("main")[0] == FileLocation(buildNormalizedPath(dir, "source/app.d"), mainLine, 6));
}
