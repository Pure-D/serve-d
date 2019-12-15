module served.commands.dub;

import served.extension;
import served.types;
import served.utils.progress;
import served.utils.translate;

import workspaced.api;
import workspaced.coms;

import painlessjson : toJSON;

import core.time;

import std.algorithm : among, canFind, count, endsWith, map, remove, startsWith;
import std.array : array;
import std.experimental.logger;
import std.json : JSONValue;
import std.path : baseName, buildPath, dirName, setExtension;
import std.regex : regex, replaceFirst;
import std.string : indexOf, join, KeepTerminator, splitLines, strip, stripLeft, stripRight;

import fs = std.file;
import io = std.stdio;

@protocolMethod("served/listConfigurations")
string[] listConfigurations()
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return null;
	return activeInstance.get!DubComponent.configurations;
}

@protocolMethod("served/switchConfig")
bool switchConfig(string value)
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return false;
	return activeInstance.get!DubComponent.setConfiguration(value);
}

@protocolMethod("served/getConfig")
string getConfig()
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return null;
	return activeInstance.get!DubComponent.configuration;
}

@protocolMethod("served/listArchTypes")
string[] listArchTypes()
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return null;
	return activeInstance.get!DubComponent.archTypes;
}

@protocolMethod("served/switchArchType")
bool switchArchType(string value)
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return false;
	return activeInstance.get!DubComponent.setArchType(JSONValue([
				"arch-type": JSONValue(value)
			]));
}

@protocolMethod("served/getArchType")
string getArchType()
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return null;
	return activeInstance.get!DubComponent.archType;
}

@protocolMethod("served/listBuildTypes")
string[] listBuildTypes()
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return null;
	return activeInstance.get!DubComponent.buildTypes;
}

@protocolMethod("served/switchBuildType")
bool switchBuildType(string value)
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return false;
	return activeInstance.get!DubComponent.setBuildType(JSONValue([
				"build-type": JSONValue(value)
			]));
}

@protocolMethod("served/getBuildType")
string getBuildType()
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return null;
	return activeInstance.get!DubComponent.buildType;
}

@protocolMethod("served/getCompiler")
string getCompiler()
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return null;
	return activeInstance.get!DubComponent.compiler;
}

@protocolMethod("served/switchCompiler")
bool switchCompiler(string value)
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return false;
	return activeInstance.get!DubComponent.setCompiler(value);
}

@protocolMethod("served/addImport")
auto addImport(AddImportParams params)
{
	auto document = documents[params.textDocument.uri];
	return backend.get!ImporterComponent.add(params.name.idup, document.rawText,
			params.location, params.insertOutermost);
}

@protocolMethod("served/updateImports")
bool updateImports(UpdateImportsParams params)
{
	auto instance = activeInstance;
	bool success;

	reportProgress(params.reportProgress, ProgressType.dubReload, 0, 5, instance.cwd.uriFromFile);

	if (instance.has!DubComponent)
	{
		success = instance.get!DubComponent.update.getYield;
		if (success)
			rpc.notifyMethod("coded/updateDubTree");
	}
	reportProgress(params.reportProgress, ProgressType.importReload, 4, 5, instance.cwd.uriFromFile);
	if (instance.has!DCDComponent)
		instance.get!DCDComponent.refreshImports();
	reportProgress(params.reportProgress, ProgressType.importReload, 5, 5, instance.cwd.uriFromFile);
	return success;
}

@protocolNotification("textDocument/didSave")
void onDidSaveDubRecipe(DidSaveTextDocumentParams params)
{
	auto workspaceUri = workspace(params.textDocument.uri).folder.uri;
	auto workspaceRoot = workspaceUri.uriToFile;
	auto fileName = params.textDocument.uri.uriToFile.baseName;

	if (fileName == "dub.json" || fileName == "dub.sdl")
	{
		info("Updating dependencies");
		reportProgress(ProgressType.importUpgrades, 0, 10, workspaceUri);
		if (!backend.has!DubComponent(workspaceRoot))
		{
			Exception err;
			const success = backend.attach(backend.getInstance(workspaceRoot), "dub", err);
			if (!success)
			{
				rpc.window.showMessage(MessageType.error, translate!"d.ext.dubUpgradeFail");
				error(err);
				reportProgress(ProgressType.importUpgrades, 10, 10, workspaceUri);
				return;
			}
		}
		else
		{
			if (backend.get!DubComponent(workspaceRoot).isRunning)
			{
				string syntaxCheck = backend.get!DubComponent(workspaceRoot)
					.validateRecipeSyntaxOnFileSystem();

				if (syntaxCheck.length)
				{
					rpc.window.showMessage(MessageType.error,
							translate!"d.ext.dubInvalidRecipeSyntax"(syntaxCheck));
					error(syntaxCheck);
					reportProgress(ProgressType.importUpgrades, 10, 10, workspaceUri);
					return;
				}

				rpc.window.runOrMessage(backend.get!DubComponent(workspaceRoot)
						.upgrade(), MessageType.warning, translate!"d.ext.dubUpgradeFail");
			}
			else
			{
				rpc.window.showMessage(MessageType.error, translate!"d.ext.dubUpgradeFail");
				reportProgress(ProgressType.importUpgrades, 10, 10, workspaceUri);
				return;
			}
		}
		reportProgress(ProgressType.importUpgrades, 6, 10, workspaceUri);

		setTimeout({
			const successfulUpdate = rpc.window.runOrMessage(backend.get!DubComponent(workspaceRoot)
				.updateImportPaths(true), MessageType.warning, translate!"d.ext.dubImportFail");
			if (successfulUpdate)
			{
				rpc.window.runOrMessage(updateImports(UpdateImportsParams(false)),
					MessageType.warning, translate!"d.ext.dubImportFail");
			}
			else
			{
				try
				{
					updateImports(UpdateImportsParams(false));
				}
				catch (Exception e)
				{
					errorf("Failed updating imports: %s", e);
				}
			}
			reportProgress(ProgressType.importUpgrades, 10, 10, workspaceUri);
		}, 200.msecs);

		setTimeout({
			if (!backend.get!DubComponent(workspaceRoot).isRunning)
			{
				Exception err;
				if (backend.attach(backend.getInstance(workspaceRoot), "dub", err))
				{
					rpc.window.runOrMessage(backend.get!DubComponent(workspaceRoot)
						.updateImportPaths(true), MessageType.warning,
						translate!"d.ext.dubRecipeMaybeBroken");
					error(err);
				}
			}
		}, 500.msecs);
		rpc.notifyMethod("coded/updateDubTree");
	}
}

@protocolMethod("served/listDependencies")
DubDependency[] listDependencies(string packageName)
{
	auto instance = activeInstance;
	DubDependency[] ret;
	auto allDeps = instance.get!DubComponent.dependencies;
	if (!packageName.length)
	{
		auto deps = instance.get!DubComponent.rootDependencies;
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

private string[] fixEmptyArgs(string[] args)
{
	return args.remove!(a => a.endsWith('='));
}

@protocolMethod("served/buildTasks")
Task[] provideBuildTasks()
{
	Task[] ret;
	foreach (instance; backend.instances)
	{
		if (!instance.has!DubComponent)
			continue;
		auto dub = instance.get!DubComponent;
		auto workspace = .workspace(instance.cwd.uriFromFile, false);
		info("Found dub package to build at ", dub.recipePath);
		string uri = dub.recipePath.dirName.uriFromFile;
		{
			Task t;
			t.source = "dub";
			t.definition = JSONValue([
					"type": JSONValue("dub"),
					"run": JSONValue(false),
					"compiler": JSONValue(dub.compiler),
					"archType": JSONValue(dub.archType),
					"buildType": JSONValue(dub.buildType),
					"configuration": JSONValue(dub.configuration)
					]);
			t.group = Task.Group.build;
			t.exec = [
				workspace.config.d.dubPath.userPath, "build", "--compiler=" ~ dub.compiler,
				"-a=" ~ dub.archType, "-b=" ~ dub.buildType, "-c=" ~ dub.configuration
			].fixEmptyArgs;
			t.scope_ = uri;
			t.name = "Build " ~ dub.name;
			ret ~= t;
		}
		{
			Task t;
			t.source = "dub";
			t.definition = JSONValue([
					"type": JSONValue("dub"),
					"run": JSONValue(true),
					"compiler": JSONValue(dub.compiler),
					"archType": JSONValue(dub.archType),
					"buildType": JSONValue(dub.buildType),
					"configuration": JSONValue(dub.configuration)
					]);
			t.group = Task.Group.build;
			t.exec = [
				workspace.config.d.dubPath.userPath, "run", "--compiler=" ~ dub.compiler,
				"-a=" ~ dub.archType, "-b=" ~ dub.buildType, "-c=" ~ dub.configuration
			].fixEmptyArgs;
			t.scope_ = uri;
			t.name = "Run " ~ dub.name;
			ret ~= t;
		}
		{
			Task t;
			t.source = "dub";
			t.definition = JSONValue([
					"type": JSONValue("dub"),
					"run": JSONValue(false),
					"force": JSONValue(true),
					"compiler": JSONValue(dub.compiler),
					"archType": JSONValue(dub.archType),
					"buildType": JSONValue(dub.buildType),
					"configuration": JSONValue(dub.configuration)
					]);
			t.group = Task.Group.rebuild;
			t.exec = [
				workspace.config.d.dubPath.userPath, "build", "--force",
				"--compiler=" ~ dub.compiler, "-a=" ~ dub.archType,
				"-b=" ~ dub.buildType, "-c=" ~ dub.configuration
			].fixEmptyArgs;
			t.scope_ = uri;
			t.name = "Rebuild " ~ dub.name;
			ret ~= t;
		}
		{
			Task t;
			t.source = "dub";
			t.definition = JSONValue([
					"type": JSONValue("dub"),
					"test": JSONValue(true),
					"compiler": JSONValue(dub.compiler),
					"archType": JSONValue(dub.archType),
					"buildType": JSONValue(dub.buildType),
					"configuration": JSONValue(dub.configuration)
					]);
			t.group = Task.Group.test;
			t.exec = [
				workspace.config.d.dubPath.userPath, "test", "--compiler=" ~ dub.compiler,
				"-a=" ~ dub.archType, "-b=" ~ dub.buildType, "-c=" ~ dub.configuration
			].fixEmptyArgs;
			t.scope_ = uri;
			t.name = "Test " ~ dub.name;
			ret ~= t;
		}
	}
	return ret;
}

// === Protocol Notifications starting here ===

@protocolNotification("served/convertDubFormat")
void convertDubFormat(DubConvertRequest req)
{
	import std.process : execute, Config;

	auto file = req.textDocument.uri.uriToFile;
	if (!fs.exists(file))
	{
		error("Specified file does not exist");
		return;
	}

	if (!file.baseName.among!("dub.json", "dub.sdl", "package.json"))
	{
		rpc.window.showErrorMessage(translate!"d.dub.notRecipeFile");
		return;
	}

	auto document = documents[req.textDocument.uri];

	auto result = execute([
			workspace(req.textDocument.uri).config.d.dubPath.userPath, "convert",
			"-f", req.newFormat, "-s"
			], null, Config.stderrPassThrough, 1024 * 1024 * 4, file.dirName);

	if (result.status != 0)
	{
		rpc.window.showErrorMessage(translate!"d.dub.convertFailed");
		return;
	}

	auto newUri = req.textDocument.uri.setExtension("." ~ req.newFormat);

	WorkspaceEdit edit;
	auto edits = [
		TextEdit(TextRange(Position(0, 0), document.offsetToPosition(document.length)), result.output)
	];

	if (capabilities.workspace.workspaceEdit.resourceOperations.canFind(ResourceOperationKind.rename))
	{
		edit.documentChanges = JSONValue([
				toJSON(RenameFile(req.textDocument.uri, newUri)),
				toJSON(TextDocumentEdit(VersionedTextDocumentIdentifier(newUri,
					document.version_), edits))
				]);
	}
	else
		edit.changes[req.textDocument.uri] = edits;
	rpc.sendMethod("workspace/applyEdit", ApplyWorkspaceEditParams(edit));
}

@protocolNotification("served/installDependency")
void installDependency(InstallRequest req)
{
	auto instance = activeInstance;
	auto uri = instance.cwd.uriFromFile;
	reportProgress(ProgressType.importUpgrades, 0, 10, uri);
	injectDependency(instance, req);
	if (instance.has!DubComponent)
		instance.get!DubComponent.upgrade();
	reportProgress(ProgressType.dubReload, 7, 10, uri);
	updateImports(UpdateImportsParams(false));
	reportProgress(ProgressType.dubReload, 10, 10, uri);
}

@protocolNotification("served/updateDependency")
void updateDependency(UpdateRequest req)
{
	auto instance = activeInstance;
	auto uri = instance.cwd.uriFromFile;
	reportProgress(ProgressType.importUpgrades, 0, 10, uri);
	if (changeDependency(instance, req))
	{
		if (instance.has!DubComponent)
			instance.get!DubComponent.upgrade();
		reportProgress(ProgressType.dubReload, 7, 10, uri);
		updateImports(UpdateImportsParams(false));
	}
	reportProgress(ProgressType.dubReload, 10, 10, uri);
}

@protocolNotification("served/uninstallDependency")
void uninstallDependency(UninstallRequest req)
{
	auto instance = activeInstance;
	auto uri = instance.cwd.uriFromFile;
	reportProgress(ProgressType.importUpgrades, 0, 10, uri);
	// TODO: add workspace argument
	removeDependency(instance, req.name);
	if (instance.has!DubComponent)
		instance.get!DubComponent.upgrade();
	reportProgress(ProgressType.dubReload, 7, 10, uri);
	updateImports(UpdateImportsParams(false));
	reportProgress(ProgressType.dubReload, 10, 10, uri);
}

void injectDependency(WorkspaceD.Instance instance, InstallRequest req)
{
	auto sdl = buildPath(instance.cwd, "dub.sdl");
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
		auto json = buildPath(instance.cwd, "dub.json");
		if (!fs.exists(json))
			json = buildPath(instance.cwd, "package.json");
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

bool changeDependency(WorkspaceD.Instance instance, UpdateRequest req)
{
	auto sdl = buildPath(instance.cwd, "dub.sdl");
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
		auto json = buildPath(instance.cwd, "dub.json");
		if (!fs.exists(json))
			json = buildPath(instance.cwd, "package.json");
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

bool removeDependency(WorkspaceD.Instance instance, string name)
{
	auto sdl = buildPath(instance.cwd, "dub.sdl");
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
		auto json = buildPath(instance.cwd, "dub.json");
		if (!fs.exists(json))
			json = buildPath(instance.cwd, "package.json");
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
