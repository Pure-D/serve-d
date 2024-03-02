module served.commands.dub;

import served.commands.index;
import served.extension;
import served.lsp.protoext;
import served.types;
import served.utils.progress;
import served.utils.translate;

import workspaced.api;
import workspaced.coms;

import core.time;

import std.algorithm : among, canFind, count, endsWith, map, remove, startsWith;
import std.array : array, replace, appender;
import std.experimental.logger;
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
bool switchConfig(SwitchConfigParams value)
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
Variant!(string, ArchType)[] listArchTypes(ListArchTypesParams params)
{
	auto ret = appender!(typeof(return));
	alias Item = typeof(ret.data[0]);
	if (!activeInstance || !activeInstance.has!DubComponent)
		return null;

	auto archTypes = activeInstance.get!DubComponent.extendedArchTypes;

	if (params.withMeaning)
	{
		foreach (archType; archTypes)
		{
			ret ~= Item(ArchType(archType.value, archType.label));
		}
	}
	else
	{
		foreach (archType; archTypes)
		{
			ret ~= Item(archType.value);
		}
	}
	return ret.data;
}

@protocolMethod("served/switchArchType")
bool switchArchType(SwitchArchTypeParams value)
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return false;
	return activeInstance.get!DubComponent.setArchType(value);
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
bool switchBuildType(SwitchBuildTypeParams value)
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return false;
	return activeInstance.get!DubComponent.setBuildType(value);
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
bool switchCompiler(SwitchCompilerParams value)
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return false;
	return activeInstance.get!DubComponent.setCompiler(value);
}

/// Returns: at least
/// ```
/// {
///     "packagePath": string,
///     "packageName": string,
///     "recipePath": string,
///     "targetPath": string,
///     "targetName": string,
///     "targetType": string,
///     "workingDirectory": string,
///     "mainSourceFile": string,
///
///     "dflags": string[],
///     "lflags": string[],
///     "libs": string[],
///     "linkerFiles": string[],
///     "sourceFiles": string[],
///     "copyFiles": string[],
///     "versions": string[],
///     "debugVersions": string[],
///     "importPaths": string[],
///     "stringImportPaths": string[],
///     "importFiles": string[],
///     "stringImportFiles": string[],
///     "preGenerateCommands": string[],
///     "postGenerateCommands": string[],
///     "preBuildCommands": string[],
///     "postBuildCommands": string[],
///     "preRunCommands": string[],
///     "postRunCommands": string[],
///     "buildOptions": string[],
///     "buildRequirements": string[],
/// }
/// ```
@protocolMethod("served/getActiveDubConfig")
StringMap!JsonValue getActiveDubConfig()
{
	if (!activeInstance || !activeInstance.has!DubComponent)
		return StringMap!JsonValue.init;
	auto ret = activeInstance.get!DubComponent.rootPackageBuildSettings();
	static assert(is(typeof(ret.packagePath) : string), "API guarantee broken");
	static assert(is(typeof(ret.packageName) : string), "API guarantee broken");
	static assert(is(typeof(ret.recipePath) : string), "API guarantee broken");
	static assert(is(typeof(ret.targetPath) : string), "API guarantee broken");
	static assert(is(typeof(ret.targetName) : string), "API guarantee broken");
	static assert(is(typeof(ret.targetType) : string), "API guarantee broken");
	static assert(is(typeof(ret.workingDirectory) : string), "API guarantee broken");
	static assert(is(typeof(ret.mainSourceFile) : string), "API guarantee broken");
	static assert(is(typeof(ret.dflags) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.lflags) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.libs) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.linkerFiles) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.sourceFiles) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.copyFiles) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.versions) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.debugVersions) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.importPaths) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.stringImportPaths) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.importFiles) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.stringImportFiles) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.preGenerateCommands) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.postGenerateCommands) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.preBuildCommands) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.postBuildCommands) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.preRunCommands) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.postRunCommands) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.buildOptions) : string[]), "API guarantee broken");
	static assert(is(typeof(ret.buildRequirements) : string[]), "API guarantee broken");

	return ret.toJsonValue.get!(StringMap!JsonValue);
}

@protocolMethod("served/addImport")
auto addImport(AddImportParams params)
{
	auto document = documents[params.textDocument.uri];
	return backend.get!ImporterComponent.add(params.name.idup, document.rawText,
			cast(int) document.offsetToBytes(params.location), params.insertOutermost);
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
	backgroundIndex();
	reportProgress(params.reportProgress, ProgressType.importReload, 5, 5, instance.cwd.uriFromFile);
	return success;
}

@protocolNotification("textDocument/didSave")
void onDidSaveDubRecipe(DidSaveTextDocumentParams params)
{
	auto fileName = params.textDocument.uri.uriToFile.baseName;
	if (!fileName.among!("dub.json", "dub.sdl"))
		return;

	auto workspaceUri = workspace(params.textDocument.uri).folder.uri;
	auto workspaceRoot = workspaceUri.uriToFile;

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

			rpc.window.runOrMessage({
				DubComponent dub = backend.get!DubComponent(workspaceRoot);
				dub.updateImportPaths(true);
				dub.selectAndDownloadMissing();
			}(), MessageType.warning, translate!"d.ext.dubUpgradeFail");
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
			.updateImportPaths(false), MessageType.warning, translate!"d.ext.dubImportFail");
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
					.updateImportPaths(false), MessageType.warning,
					translate!"d.ext.dubRecipeMaybeBroken");
				error(err);
			}
		}
	}, 500.msecs);
	rpc.notifyMethod("coded/updateDubTree");
}

@protocolMethod("served/listDependencies")
DubDependency[] listDependencies(ListDependenciesParams params)
{
	auto instance = activeInstance;
	DubDependency[] ret;
	if (!instance.has!DubComponent)
		return ret;

	auto dub = instance.get!DubComponent;
	auto failed = dub.failedPackages;
	if (!params.packageName.length)
	{
		auto deps = dub.rootDependencies;
		foreach (dep; deps)
		{
			DubDependency r;
			r.name = dep;
			r.failed = failed.canFind(dep);
			r.root = true;
			auto other = dub.getPackageInfo(dep);
			r.version_ = other.ver;
			r.path = other.path;
			r.description = other.description;
			r.homepage = other.homepage;
			r.authors = other.authors;
			r.copyright = other.copyright;
			r.license = other.license;
			r.subPackages = other.subPackages.map!"a.name".array;
			r.hasDependencies = other.dependencies.length > 0;
			ret ~= r;
		}
	}
	else
	{
		auto info = dub.getPackageInfo(params.packageName);
		string[string] aa = info.dependencies;
		foreach (name, ver; aa)
		{
			DubDependency r;
			r.name = name;
			r.failed = failed.canFind(name);
			r.version_ = ver;
			auto other = dub.getPackageInfo(name);
			r.path = other.path;
			r.description = other.description;
			r.homepage = other.homepage;
			r.authors = other.authors;
			r.copyright = other.copyright;
			r.license = other.license;
			r.subPackages = other.subPackages.map!"a.name".array;
			r.hasDependencies = other.dependencies.length > 0;
			ret ~= r;
		}
	}
	return ret;
}

private string[] fixEmptyArgs(string[] args)
{
	return args.remove!(a => a.endsWith('='));
}

__gshared bool useBuildTaskDollarCurrent = false;
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

		if (!dub.isValidBuildConfiguration)
		{
			info("\t=> not a buildable project, skipping");
			continue;
		}

		JsonValue dollarMagicValue;
		if (useBuildTaskDollarCurrent)
			dollarMagicValue = JsonValue("$current");

		JsonValue currentValue(string prop)()
		{
			if (useBuildTaskDollarCurrent)
				return JsonValue("$current");
			else
				return JsonValue(__traits(getMember, dub, prop));
		}

		auto cwd = JsonValue(dub.recipePath.dirName.replace(workspace.folder.uri.uriToFile, "${workspaceFolder}"));
		{
			Task t;
			t.source = "dub";
			t.definition = JsonValue([
				"type": JsonValue("dub"),
				"run": JsonValue(true),
				"compiler": currentValue!"compiler",
				"archType": currentValue!"archType",
				"buildType": currentValue!"buildType",
				"configuration": currentValue!"configuration",
				"cwd": cwd
			]);
			t.group = Task.Group.build;
			t.exec = [
				workspace.config.d.dubPath.userPath, "run", "--compiler=" ~ dub.compiler,
				"-a=" ~ dub.archType, "-b=" ~ dub.buildType, "-c=" ~ dub.configuration
			].fixEmptyArgs;
			t.scope_ = workspace.folder.uri;
			t.name = "Run " ~ dub.name;
			ret ~= t;
		}
		{
			Task t;
			t.source = "dub";
			t.definition = JsonValue([
				"type": JsonValue("dub"),
				"test": JsonValue(true),
				"compiler": currentValue!"compiler",
				"archType": currentValue!"archType",
				"buildType": currentValue!"buildType",
				"configuration": currentValue!"configuration",
				"cwd": cwd
			]);
			t.group = Task.Group.test;
			t.exec = [
				workspace.config.d.dubPath.userPath, "test", "--compiler=" ~ dub.compiler,
				"-a=" ~ dub.archType, "-b=" ~ dub.buildType, "-c=" ~ dub.configuration
			].fixEmptyArgs;
			t.scope_ = workspace.folder.uri;
			t.name = "Test " ~ dub.name;
			ret ~= t;
		}
		{
			Task t;
			t.source = "dub";
			t.definition = JsonValue([
				"type": JsonValue("dub"),
				"run": JsonValue(false),
				"compiler": currentValue!"compiler",
				"archType": currentValue!"archType",
				"buildType": currentValue!"buildType",
				"configuration": currentValue!"configuration",
				"cwd": cwd
			]);
			t.group = Task.Group.build;
			t.exec = [
				workspace.config.d.dubPath.userPath, "build", "--compiler=" ~ dub.compiler,
				"-a=" ~ dub.archType, "-b=" ~ dub.buildType, "-c=" ~ dub.configuration
			].fixEmptyArgs;
			t.scope_ = workspace.folder.uri;
			t.name = "Build " ~ dub.name;
			ret ~= t;
		}
		{
			Task t;
			t.source = "dub";
			t.definition = JsonValue([
				"type": JsonValue("dub"),
				"run": JsonValue(false),
				"force": JsonValue(true),
				"compiler": currentValue!"compiler",
				"archType": currentValue!"archType",
				"buildType": currentValue!"buildType",
				"configuration": currentValue!"configuration",
				"cwd": cwd
			]);
			t.group = Task.Group.rebuild;
			t.exec = [
				workspace.config.d.dubPath.userPath, "build", "--force",
				"--compiler=" ~ dub.compiler, "-a=" ~ dub.archType,
				"-b=" ~ dub.buildType, "-c=" ~ dub.configuration
			].fixEmptyArgs;
			t.scope_ = workspace.folder.uri;
			t.name = "Rebuild " ~ dub.name;
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

	if (capabilities
		.workspace.orDefault
		.workspaceEdit.orDefault
		.resourceOperations.orDefault
		.canFind(ResourceOperationKind.rename))
	{
		edit.documentChanges = [
			DocumentChange(RenameFile(req.textDocument.uri, newUri)),
			DocumentChange(TextDocumentEdit(
				VersionedTextDocumentIdentifier(newUri, document.version_),
				edits
			))
		];
	}
	else
		edit.changes[req.textDocument.uri] = edits;

	ApplyWorkspaceEditParams params = {
		edit: edit
	};
	rpc.sendMethod("workspace/applyEdit", params);
}

@protocolNotification("served/installDependency")
void installDependency(InstallRequest req)
{
	auto instance = activeInstance;
	auto uri = instance.cwd.uriFromFile;
	reportProgress(ProgressType.importUpgrades, 0, 10, uri);
	injectDependency(instance, req);
	if (instance.has!DubComponent)
		instance.get!DubComponent.selectAndDownloadMissing();
	reportProgress(ProgressType.dubReload, 7, 10, uri);
	updateImports(UpdateImportsParams(false));
	reportProgress(ProgressType.dubReload, 10, 10, uri);
}

@protocolNotification("served/updateDependency")
void updateDependency(UpdateRequest req)
{
	// TODO: update in dub.selections.json

	auto instance = activeInstance;
	auto uri = instance.cwd.uriFromFile;
	reportProgress(ProgressType.importUpgrades, 0, 10, uri);
	if (changeDependency(instance, req))
	{
		if (instance.has!DubComponent)
			instance.get!DubComponent.selectAndDownloadMissing();
		reportProgress(ProgressType.dubReload, 7, 10, uri);
		updateImports(UpdateImportsParams(false));
	}
	reportProgress(ProgressType.dubReload, 10, 10, uri);
}

@protocolNotification("served/uninstallDependency")
void uninstallDependency(UninstallRequest req)
{
	// TODO: remove from dub.selections.json

	auto instance = activeInstance;
	auto uri = instance.cwd.uriFromFile;
	reportProgress(ProgressType.importUpgrades, 0, 10, uri);
	// TODO: add workspace argument
	removeDependency(instance, req.name);
	if (instance.has!DubComponent)
		instance.get!DubComponent.selectAndDownloadMissing();
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
