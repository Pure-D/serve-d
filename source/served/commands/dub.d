module served.commands.dub;

import served.extension;
import served.types;

import workspaced.api;
import workspaced.coms;

import std.array : array;
import std.algorithm : map, count, startsWith, endsWith;
import std.json : JSONValue;
import std.path : buildPath;
import std.regex : regex, replaceFirst;
import std.string : splitLines, KeepTerminator, strip, stripLeft, stripRight, indexOf, join;

import fs = std.file;
import io = std.stdio;

@protocolMethod("served/listConfigurations")
string[] listConfigurations()
{
	return backend.get!DubComponent(selectedWorkspaceRoot).configurations;
}

@protocolMethod("served/switchConfig")
bool switchConfig(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot).setConfiguration(value);
}

@protocolMethod("served/getConfig")
string getConfig(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot).configuration;
}

@protocolMethod("served/listArchTypes")
string[] listArchTypes()
{
	return backend.get!DubComponent(selectedWorkspaceRoot).archTypes;
}

@protocolMethod("served/switchArchType")
bool switchArchType(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot)
		.setArchType(JSONValue(["arch-type" : JSONValue(value)]));
}

@protocolMethod("served/getArchType")
string getArchType(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot).archType;
}

@protocolMethod("served/listBuildTypes")
string[] listBuildTypes()
{
	return backend.get!DubComponent(selectedWorkspaceRoot).buildTypes;
}

@protocolMethod("served/switchBuildType")
bool switchBuildType(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot)
		.setBuildType(JSONValue(["build-type" : JSONValue(value)]));
}

@protocolMethod("served/getBuildType")
string getBuildType()
{
	return backend.get!DubComponent(selectedWorkspaceRoot).buildType;
}

@protocolMethod("served/getCompiler")
string getCompiler()
{
	return backend.get!DubComponent(selectedWorkspaceRoot).compiler;
}

@protocolMethod("served/switchCompiler")
bool switchCompiler(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot).setCompiler(value);
}

@protocolMethod("served/addImport")
auto addImport(AddImportParams params)
{
	auto document = documents[params.textDocument.uri];
	return backend.get!ImporterComponent.add(params.name.idup, document.text,
			params.location, params.insertOutermost);
}

@protocolMethod("served/updateImports")
bool updateImports()
{
	auto workspaceRoot = selectedWorkspaceRoot;
	bool success;
	if (backend.has!DubComponent(workspaceRoot))
	{
		success = backend.get!DubComponent(workspaceRoot).update.getYield;
		if (success)
			rpc.notifyMethod("coded/updateDubTree");
	}
	if (backend.has!DCDComponent(workspaceRoot))
		backend.get!DCDComponent(workspaceRoot).refreshImports();
	return success;
}

@protocolMethod("served/listDependencies")
DubDependency[] listDependencies(string packageName)
{
	auto workspaceRoot = selectedWorkspaceRoot;
	DubDependency[] ret;
	auto allDeps = backend.get!DubComponent(workspaceRoot).dependencies;
	if (!packageName.length)
	{
		auto deps = backend.get!DubComponent(workspaceRoot).rootDependencies;
		foreach (dep; deps)
		{
			DubDependency r;
			r.name = dep;
			r.root = true;
			foreach (other; allDeps)
				if (other.name == dep)
				{
					r.version_ = other.ver;
					r.path = other.path;
					r.description = other.description;
					r.homepage = other.homepage;
					r.authors = other.authors;
					r.copyright = other.copyright;
					r.license = other.license;
					r.subPackages = other.subPackages.map!"a.name".array;
					r.hasDependencies = other.dependencies.length > 0;
					break;
				}
			ret ~= r;
		}
	}
	else
	{
		string[string] aa;
		foreach (other; allDeps)
			if (other.name == packageName)
			{
				aa = other.dependencies;
				break;
			}
		foreach (name, ver; aa)
		{
			DubDependency r;
			r.name = name;
			r.version_ = ver;
			foreach (other; allDeps)
				if (other.name == name)
				{
					r.path = other.path;
					r.description = other.description;
					r.homepage = other.homepage;
					r.authors = other.authors;
					r.copyright = other.copyright;
					r.license = other.license;
					r.subPackages = other.subPackages.map!"a.name".array;
					r.hasDependencies = other.dependencies.length > 0;
					break;
				}
			ret ~= r;
		}
	}
	return ret;
}

@protocolMethod("served/buildTasks")
Task[] provideBuildTasks()
{
	Task[] ret;
	foreach (ref workspace; workspaces)
	{
		auto workspaceRoot = workspace.folder.uri.uriToFile;
		if (!backend.has!DubComponent(workspaceRoot))
			continue;
		auto dub = backend.get!DubComponent(workspaceRoot);
		{
			Task t;
			t.source = "dub";
			t.definition = JSONValue(["type" : JSONValue("dub"), "run" : JSONValue(false),
					"compiler" : JSONValue(dub.compiler), "archType" : JSONValue(dub.archType),
					"buildType" : JSONValue(dub.buildType), "configuration" : JSONValue(dub.configuration)]);
			t.group = Task.Group.build;
			t.exec = [workspace.config.d.dubPath.userPath, "build",
				"--compiler=" ~ dub.compiler, "-a=" ~ dub.archType, "-b=" ~ dub.buildType,
				"-c=" ~ dub.configuration];
			t.scope_ = workspace.folder.uri;
			t.name = "Build " ~ dub.name;
			ret ~= t;
		}
		{
			Task t;
			t.source = "dub";
			t.definition = JSONValue(["type" : JSONValue("dub"), "run" : JSONValue(true),
					"compiler" : JSONValue(dub.compiler), "archType" : JSONValue(dub.archType),
					"buildType" : JSONValue(dub.buildType), "configuration" : JSONValue(dub.configuration)]);
			t.group = Task.Group.build;
			t.exec = [workspace.config.d.dubPath.userPath, "run",
				"--compiler=" ~ dub.compiler, "-a=" ~ dub.archType, "-b=" ~ dub.buildType,
				"-c=" ~ dub.configuration];
			t.scope_ = workspace.folder.uri;
			t.name = "Run " ~ dub.name;
			ret ~= t;
		}
		{
			Task t;
			t.source = "dub";
			t.definition = JSONValue(["type" : JSONValue("dub"), "run"
					: JSONValue(false), "force" : JSONValue(true), "compiler" : JSONValue(dub.compiler),
					"archType" : JSONValue(dub.archType), "buildType"
					: JSONValue(dub.buildType), "configuration" : JSONValue(dub.configuration)]);
			t.group = Task.Group.rebuild;
			t.exec = [workspace.config.d.dubPath.userPath, "build", "--force",
				"--compiler=" ~ dub.compiler, "-a=" ~ dub.archType, "-b=" ~ dub.buildType,
				"-c=" ~ dub.configuration];
			t.scope_ = workspace.folder.uri;
			t.name = "Rebuild " ~ dub.name;
			ret ~= t;
		}
		{
			Task t;
			t.source = "dub";
			t.definition = JSONValue(["type" : JSONValue("dub"), "test" : JSONValue(true),
					"compiler" : JSONValue(dub.compiler), "archType" : JSONValue(dub.archType),
					"buildType" : JSONValue(dub.buildType), "configuration" : JSONValue(dub.configuration)]);
			t.group = Task.Group.test;
			t.exec = [workspace.config.d.dubPath.userPath, "test",
				"--compiler=" ~ dub.compiler, "-a=" ~ dub.archType, "-b=" ~ dub.buildType,
				"-c=" ~ dub.configuration];
			t.scope_ = workspace.folder.uri;
			t.name = "Test " ~ dub.name;
			ret ~= t;
		}
	}
	return ret;
}

// === Protocol Notifications starting here ===

@protocolNotification("served/installDependency")
void installDependency(InstallRequest req)
{
	auto workspaceRoot = selectedWorkspaceRoot;
	injectDependency(workspaceRoot, req);
	if (backend.has!DubComponent(workspaceRoot))
	{
		backend.get!DubComponent(workspaceRoot).upgrade();
		backend.get!DubComponent(workspaceRoot).updateImportPaths(true);
	}
	updateImports();
}

@protocolNotification("served/updateDependency")
void updateDependency(UpdateRequest req)
{
	auto workspaceRoot = selectedWorkspaceRoot;
	if (changeDependency(workspaceRoot, req))
	{
		if (backend.has!DubComponent(workspaceRoot))
		{
			backend.get!DubComponent(workspaceRoot).upgrade();
			backend.get!DubComponent(workspaceRoot).updateImportPaths(true);
		}
		updateImports();
	}
}

@protocolNotification("served/uninstallDependency")
void uninstallDependency(UninstallRequest req)
{
	auto workspaceRoot = selectedWorkspaceRoot;
	// TODO: add workspace argument
	removeDependency(workspaceRoot, req.name);
	if (backend.has!DubComponent(workspaceRoot))
	{
		backend.get!DubComponent(workspaceRoot).upgrade();
		backend.get!DubComponent(workspaceRoot).updateImportPaths(true);
	}
	updateImports();
}

void injectDependency(string workspaceRoot, InstallRequest req)
{
	auto sdl = buildPath(workspaceRoot, "dub.sdl");
	if (fs.exists(sdl))
	{
		int depth = 0;
		auto content = fs.readText(sdl).splitLines(KeepTerminator.yes);
		auto insertAt = content.length;
		bool gotLineEnding = false;
		string lineEnding = "\n";
		foreach (i, line; content)
		{
			if (!gotLineEnding && line.length >= 2)
			{
				lineEnding = line[$ - 2 .. $];
				if (lineEnding[0] != '\r')
					lineEnding = line[$ - 1 .. $];
				gotLineEnding = true;
			}
			if (depth == 0 && line.strip.startsWith("dependency "))
				insertAt = i + 1;
			depth += line.count('{') - line.count('}');
		}
		content = content[0 .. insertAt] ~ ((insertAt == content.length ? lineEnding
				: "") ~ "dependency \"" ~ req.name ~ "\" version=\"~>" ~ req.version_ ~ "\"" ~ lineEnding)
			~ content[insertAt .. $];
		fs.write(sdl, content.join());
	}
	else
	{
		auto json = buildPath(workspaceRoot, "dub.json");
		if (!fs.exists(json))
			json = buildPath(workspaceRoot, "package.json");
		if (!fs.exists(json))
			return;
		auto content = fs.readText(json).splitLines(KeepTerminator.yes);
		auto insertAt = content.length ? content.length - 1 : 0;
		string lineEnding = "\n";
		bool gotLineEnding = false;
		int depth = 0;
		bool insertNext;
		string indent;
		bool foundBlock;
		foreach (i, line; content)
		{
			if (!gotLineEnding && line.length >= 2)
			{
				lineEnding = line[$ - 2 .. $];
				if (lineEnding[0] != '\r')
					lineEnding = line[$ - 1 .. $];
				gotLineEnding = true;
			}
			if (insertNext)
			{
				indent = line[0 .. $ - line.stripLeft.length];
				insertAt = i + 1;
				break;
			}
			if (depth == 1 && line.strip.startsWith(`"dependencies":`))
			{
				foundBlock = true;
				if (line.strip.endsWith("{"))
				{
					indent = line[0 .. $ - line.stripLeft.length];
					insertAt = i + 1;
					break;
				}
				else
				{
					insertNext = true;
				}
			}
			depth += line.count('{') - line.count('}') + line.count('[') - line.count(']');
		}
		if (foundBlock)
		{
			content = content[0 .. insertAt] ~ (
					indent ~ indent ~ `"` ~ req.name ~ `": "~>` ~ req.version_ ~ `",` ~ lineEnding)
				~ content[insertAt .. $];
			fs.write(json, content.join());
		}
		else if (content.length)
		{
			if (content.length > 1)
				content[$ - 2] = content[$ - 2].stripRight;
			content = content[0 .. $ - 1] ~ (
					"," ~ lineEnding ~ `	"dependencies": {
		"` ~ req.name ~ `": "~>` ~ req.version_ ~ `"
	}` ~ lineEnding)
				~ content[$ - 1 .. $];
			fs.write(json, content.join());
		}
		else
		{
			content ~= `{
	"dependencies": {
		"` ~ req.name ~ `": "~>` ~ req.version_ ~ `"
	}
}`;
			fs.write(json, content.join());
		}
	}
}

bool changeDependency(string workspaceRoot, UpdateRequest req)
{
	auto sdl = buildPath(workspaceRoot, "dub.sdl");
	if (fs.exists(sdl))
	{
		int depth = 0;
		auto content = fs.readText(sdl).splitLines(KeepTerminator.yes);
		size_t target = size_t.max;
		foreach (i, line; content)
		{
			if (depth == 0 && line.strip.startsWith("dependency ")
					&& line.strip["dependency".length .. $].strip.startsWith('"' ~ req.name ~ '"'))
			{
				target = i;
				break;
			}
			depth += line.count('{') - line.count('}');
		}
		if (target == size_t.max)
			return false;
		auto ver = content[target].indexOf("version");
		if (ver == -1)
			return false;
		auto quotStart = content[target].indexOf("\"", ver);
		if (quotStart == -1)
			return false;
		auto quotEnd = content[target].indexOf("\"", quotStart + 1);
		if (quotEnd == -1)
			return false;
		content[target] = content[target][0 .. quotStart] ~ '"' ~ req.version_ ~ '"'
			~ content[target][quotEnd .. $];
		fs.write(sdl, content.join());
		return true;
	}
	else
	{
		auto json = buildPath(workspaceRoot, "dub.json");
		if (!fs.exists(json))
			json = buildPath(workspaceRoot, "package.json");
		if (!fs.exists(json))
			return false;
		auto content = fs.readText(json);
		auto replaced = content.replaceFirst(regex(`("` ~ req.name ~ `"\s*:\s*)"[^"]*"`),
				`$1"` ~ req.version_ ~ `"`);
		if (content == replaced)
			return false;
		fs.write(json, replaced);
		return true;
	}
}

bool removeDependency(string workspaceRoot, string name)
{
	auto sdl = buildPath(workspaceRoot, "dub.sdl");
	if (fs.exists(sdl))
	{
		int depth = 0;
		auto content = fs.readText(sdl).splitLines(KeepTerminator.yes);
		size_t target = size_t.max;
		foreach (i, line; content)
		{
			if (depth == 0 && line.strip.startsWith("dependency ")
					&& line.strip["dependency".length .. $].strip.startsWith('"' ~ name ~ '"'))
			{
				target = i;
				break;
			}
			depth += line.count('{') - line.count('}');
		}
		if (target == size_t.max)
			return false;
		fs.write(sdl, (content[0 .. target] ~ content[target + 1 .. $]).join());
		return true;
	}
	else
	{
		auto json = buildPath(workspaceRoot, "dub.json");
		if (!fs.exists(json))
			json = buildPath(workspaceRoot, "package.json");
		if (!fs.exists(json))
			return false;
		auto content = fs.readText(json);
		auto replaced = content.replaceFirst(regex(`"` ~ name ~ `"\s*:\s*"[^"]*"\s*,\s*`), "");
		if (content == replaced)
			replaced = content.replaceFirst(regex(`\s*,\s*"` ~ name ~ `"\s*:\s*"[^"]*"`), "");
		if (content == replaced)
			replaced = content.replaceFirst(regex(
					`"dependencies"\s*:\s*\{\s*"` ~ name ~ `"\s*:\s*"[^"]*"\s*\}\s*,\s*`), "");
		if (content == replaced)
			replaced = content.replaceFirst(regex(
					`\s*,\s*"dependencies"\s*:\s*\{\s*"` ~ name ~ `"\s*:\s*"[^"]*"\s*\}`), "");
		if (content == replaced)
			return false;
		fs.write(json, replaced);
		return true;
	}
}
