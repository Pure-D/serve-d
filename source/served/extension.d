module served.extension;

import served.fibermanager;
import served.nothrow_fs;
import served.translate;
import served.types;

public import served.async;

import core.time : msecs, seconds;

import std.algorithm : any, canFind, endsWith, map;
import std.array : appender, array;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.datetime.systime : Clock, SysTime;
import std.experimental.logger;
import std.format : format;
import std.functional : toDelegate;
import std.json : JSONType, JSONValue, parseJSON;
import std.meta : AliasSeq;
import std.path : baseName, buildNormalizedPath, buildPath, chainPath, dirName,
	globMatch, relativePath;
import std.string : join;

import io = std.stdio;

import workspaced.api;
import workspaced.coms;

version (ARM)
{
	version = DCDFromSource;
}

version (Win32)
{
}
else version (Win64)
{
}
else version (linux)
{
}
else version (OSX)
{
}
else version = DCDFromSource;

/// Set to true when shutdown is called
__gshared bool shutdownRequested;

void changedConfig(string workspaceUri, string[] paths,
		served.types.Configuration config, bool allowFallback = false)
{
	StopWatch sw;
	sw.start();

	if (!workspaceUri.length)
	{
		if (!allowFallback)
			error("Passed invalid empty workspace uri to changedConfig!");
		trace("Updated fallback config (user settings) for sections ", paths);
		return;
	}

	if (!syncedConfiguration && !allowFallback)
	{
		syncedConfiguration = true;
		doGlobalStartup();
	}

	Workspace* proj = &workspace(workspaceUri);
	bool isFallback = proj is &fallbackWorkspace;
	if (isFallback && !allowFallback)
	{
		error("Did not find workspace ", workspaceUri, " when updating config?");
		return;
	}
	else if (isFallback)
	{
		trace("Updated fallback config (user settings) for sections ", paths);
		return;
	}

	if (!proj.initialized)
	{
		doStartup(proj.folder.uri);
		proj.initialized = true;
	}

	auto workspaceFs = workspaceUri.uriToFile;

	foreach (path; paths)
	{
		switch (path)
		{
		case "d.stdlibPath":
			if (backend.has!DCDComponent(workspaceFs))
				backend.get!DCDComponent(workspaceFs).addImports(config.stdlibPath(workspaceFs));
			break;
		case "d.projectImportPaths":
			if (backend.has!DCDComponent(workspaceFs))
				backend.get!DCDComponent(workspaceFs)
					.addImports(config.d.projectImportPaths.map!(a => a.userPath).array);
			break;
		case "d.dubConfiguration":
			if (backend.has!DubComponent(workspaceFs))
			{
				auto configs = backend.get!DubComponent(workspaceFs).configurations;
				if (configs.length == 0)
					rpc.window.showInformationMessage(translate!"d.ext.noConfigurations.project");
				else
				{
					auto defaultConfig = config.d.dubConfiguration;
					if (defaultConfig.length)
					{
						if (!configs.canFind(defaultConfig))
							rpc.window.showErrorMessage(
									translate!"d.ext.config.invalid.configuration"(defaultConfig));
						else
							backend.get!DubComponent(workspaceFs).setConfiguration(defaultConfig);
					}
					else
						backend.get!DubComponent(workspaceFs).setConfiguration(configs[0]);
				}
			}
			break;
		case "d.dubArchType":
			if (backend.has!DubComponent(workspaceFs) && config.d.dubArchType.length
					&& !backend.get!DubComponent(workspaceFs)
					.setArchType(JSONValue(["arch-type": JSONValue(config.d.dubArchType)])))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.archType"(config.d.dubArchType));
			break;
		case "d.dubBuildType":
			if (backend.has!DubComponent(workspaceFs) && config.d.dubBuildType.length
					&& !backend.get!DubComponent(workspaceFs)
					.setBuildType(JSONValue([
							"build-type": JSONValue(config.d.dubBuildType)
						])))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.buildType"(config.d.dubBuildType));
			break;
		case "d.dubCompiler":
			if (backend.has!DubComponent(workspaceFs) && config.d.dubCompiler.length
					&& !backend.get!DubComponent(workspaceFs).setCompiler(config.d.dubCompiler))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.compiler"(config.d.dubCompiler));
			break;
		case "d.enableAutoComplete":
			if (config.d.enableAutoComplete)
			{
				if (!backend.has!DCDComponent(workspaceFs))
				{
					auto instance = backend.getInstance(workspaceFs);
					prepareDCD(instance, workspaceUri);
					startDCDServer(instance, workspaceUri);
				}
			}
			else if (backend.has!DCDComponent(workspaceFs))
			{
				backend.get!DCDComponent(workspaceFs).stopServer();
			}
			break;
		case "d.enableLinting":
			if (!config.d.enableLinting)
			{
				import served.linters.dscanner : clear1 = clear;
				import served.linters.dub : clear2 = clear;

				clear1();
				clear2();
			}
			break;
		case "d.enableStaticLinting":
			if (!config.d.enableStaticLinting)
			{
				import served.linters.dscanner : clear;

				clear();
			}
			break;
		case "d.enableDubLinting":
			if (!config.d.enableDubLinting)
			{
				import served.linters.dub : clear;

				clear();
			}
			break;
		default:
			break;
		}
	}

	trace("Finished config change of ", workspaceUri, " with ", paths.length,
			" changes in ", sw.peek, ".");
}

void processConfigChange(served.types.Configuration configuration)
{
	import painlessjson : fromJSON;

	syncingConfiguration = true;
	scope (exit)
		syncingConfiguration = false;

	if (capabilities.workspace.configuration && workspaces.length >= 2)
	{
		ConfigurationItem[] items;
		foreach (section; configurationSections)
			items ~= ConfigurationItem(Optional!string.init, opt(section)); // default workspace

		foreach (workspace; workspaces)
			foreach (section; configurationSections)
				items ~= ConfigurationItem(opt(workspace.folder.uri), opt(section));
		trace("Re-requesting configuration from client because there is more than 1 workspace");
		auto res = rpc.sendRequest("workspace/configuration", ConfigurationParams(items));
		if (res.result.type == JSONType.array && res.result.array.length >= 1)
		{
			JSONValue[] settings = res.result.array;
			if (settings.length % configurationSections.length != 0)
			{
				error("Got invalid configuration response from language client.");
				trace("Response: ", res);
				return;
			}
			for (size_t i = 0; i < settings.length; i += configurationSections.length)
			{
				auto workspace = i == 0 ? &fallbackWorkspace : &.workspace(items[i].scopeUri.get, false);
				string[] changed;
				static foreach (n, section; configurationSections)
					changed ~= workspace.config.replaceSection!section(
							settings[i + n].fromJSON!(configurationTypes[n]));
				changedConfig(i == 0 ? null : workspace.folder.uri, changed, workspace.config, i == 0);
			}
		}
	}
	else if (workspaces.length)
	{
		if (workspaces.length > 1)
			error(
					"Client does not support configuration request, only applying config for first workspace.");
		auto changed = workspaces[0].config.replace(configuration);
		changedConfig(workspaces[0].folder.uri, changed, workspaces[0].config);
		fallbackWorkspace.config = workspaces[0].config;
	}
}

bool syncConfiguration(string workspaceUri)
{
	import painlessjson : fromJSON;

	if (capabilities.workspace.configuration)
	{
		Workspace* proj = &workspace(workspaceUri);
		if (proj is &fallbackWorkspace && workspaceUri.length)
		{
			error("Did not find workspace ", workspaceUri, " when syncing config?");
			return false;
		}
		ConfigurationItem[] items;
		foreach (section; configurationSections)
			items ~= ConfigurationItem(workspaceUri.length
					? opt(proj.folder.uri) : Optional!string.init, opt(section));
		auto res = rpc.sendRequest("workspace/configuration", ConfigurationParams(items));
		trace("Sending workspace/configuration request for ", workspaceUri);
		if (res.result.type == JSONType.array)
		{
			JSONValue[] settings = res.result.array;
			if (settings.length % configurationSections.length != 0)
			{
				error("Got invalid configuration response from language client.");
				trace("Response: ", res);
				return false;
			}
			string[] changed;
			static foreach (n, section; configurationSections)
				changed ~= proj.config.replaceSection!section(
						settings[n].fromJSON!(configurationTypes[n]));
			changedConfig(proj.folder.uri, changed, proj.config, workspaceUri.length == 0);
			return true;
		}
		else
			return false;
	}
	else
		return false;
}

string[] getPossibleSourceRoots(string workspaceFolder)
{
	import std.path : isAbsolute;
	import std.file;

	auto confPaths = config(workspaceFolder.uriFromFile, false).d.projectImportPaths.map!(
			a => a.isAbsolute ? a : buildNormalizedPath(workspaceRoot, a));
	if (!confPaths.empty)
		return confPaths.array;
	auto a = buildNormalizedPath(workspaceFolder, "source");
	auto b = buildNormalizedPath(workspaceFolder, "src");
	if (exists(a))
		return [a];
	if (exists(b))
		return [b];
	return [workspaceFolder];
}

__gshared bool syncedConfiguration = false;
__gshared bool syncingConfiguration = false;
InitializeResult initialize(InitializeParams params)
{
	import std.file : chdir;

	capabilities = params.capabilities;
	trace("initialize params:");
	prettyPrintStruct!trace(params);

	if (params.workspaceFolders.length)
		workspaces = params.workspaceFolders.map!(a => Workspace(a,
				served.types.Configuration.init)).array;
	else if (params.rootUri.length)
		workspaces = [
			Workspace(WorkspaceFolder(params.rootUri, "Root"), served.types.Configuration.init)
		];
	else if (params.rootPath.length)
		workspaces = [
			Workspace(WorkspaceFolder(params.rootPath.uriFromFile, "Root"),
					served.types.Configuration.init)
		];
	if (workspaces.length)
	{
		fallbackWorkspace.folder = workspaces[0].folder;
		fallbackWorkspace.initialized = true;
	}

	InitializeResult result;
	result.capabilities.textDocumentSync = documents.syncKind;
	result.capabilities.completionProvider = CompletionOptions(false, [
			".", "=", "*", "/", "+", "-", "%"
			]);
	result.capabilities.signatureHelpProvider = SignatureHelpOptions([
			"(", "[", ","
			]);
	result.capabilities.workspaceSymbolProvider = true;
	result.capabilities.definitionProvider = true;
	result.capabilities.hoverProvider = true;
	result.capabilities.codeActionProvider = true;
	result.capabilities.codeLensProvider = CodeLensOptions(true);
	result.capabilities.documentSymbolProvider = true;
	result.capabilities.documentFormattingProvider = true;
	result.capabilities.workspace = opt(ServerWorkspaceCapabilities(
			opt(ServerWorkspaceCapabilities.WorkspaceFolders(opt(true), opt(true)))));

	setTimeout({
		if (!syncedConfiguration && !syncingConfiguration && capabilities.workspace.configuration)
		{
			if (!syncConfiguration(null))
				error("Syncing user configuration failed!");

			warning(
				"Didn't receive any configuration notification, manually requesting all configurations now");

			foreach (ref workspace; workspaces)
				syncConfiguration(workspace.folder.uri);
		}
	}, 1000);

	return result;
}

void doGlobalStartup()
{
	try
	{
		trace("Initializing serve-d for global access");

		backend.globalConfiguration.base = JSONValue(
				[
				"dcd": JSONValue([
						"clientPath": JSONValue(firstConfig.d.dcdClientPath.userPath),
						"serverPath": JSONValue(firstConfig.d.dcdServerPath.userPath),
						"port": JSONValue(9166)
					]),
				"dmd": JSONValue(["path": JSONValue(firstConfig.d.dmdPath.userPath)])
				]);

		trace("Setup global configuration as " ~ backend.globalConfiguration.base.toString);

		trace("Registering dub");
		backend.register!DubComponent(false);
		trace("Registering fsworkspace");
		backend.register!FSWorkspaceComponent(false);
		trace("Registering dcd");
		backend.register!DCDComponent(false);
		trace("Registering dcdext");
		backend.register!DCDExtComponent(false);
		trace("Registering dmd");
		backend.register!DMDComponent(false);
		trace("Starting dscanner");
		backend.register!DscannerComponent;
		trace("Starting dfmt");
		backend.register!DfmtComponent;
		trace("Starting dlangui");
		backend.register!DlanguiComponent;
		trace("Starting importer");
		backend.register!ImporterComponent;
		trace("Starting moduleman");
		backend.register!ModulemanComponent;

		if (!backend.has!DCDComponent || backend.get!DCDComponent.isOutdated)
		{
			auto installed = backend.has!DCDComponent
				? backend.get!DCDComponent.clientInstalledVersion : "none";

			string outdatedMessage = translate!"d.served.outdatedDCD"(
					DCDComponent.latestKnownVersion.to!(string[]).join("."), installed);

			dcdUpdating = true;
			dcdUpdateReason = format!"DCD is outdated. Expected: %(%s.%), got %s"(
					DCDComponent.latestKnownVersion, installed);
			if (firstConfig.d.aggressiveUpdate)
				spawnFiber((&updateDCD).toDelegate);
			else
			{
				spawnFiber({
					version (DCDFromSource)
						auto action = translate!"d.ext.compileProgram"("DCD");
					else
						auto action = translate!"d.ext.downloadProgram"("DCD");

					auto res = rpc.window.requestMessage(MessageType.error, outdatedMessage, [
							action
						]);

					if (res == action)
						spawnFiber((&updateDCD).toDelegate);
				}, 4);
			}
		}
	}
	catch (Exception e)
	{
		error("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
		error("Failed to fully globally initialize:");
		error(e);
		error("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
	}
}

struct RootSuggestion
{
	string dir;
	bool useDub;
}

RootSuggestion[] rootsForProject(string root, bool recursive, string[] blocked,
		string[] extra, ManyProjectsAction manyAction, int manyThreshold)
{
	RootSuggestion[] ret;
	bool rootDub = fs.exists(chainPath(root, "dub.json")) || fs.exists(chainPath(root, "dub.sdl"));
	if (!rootDub && fs.exists(chainPath(root, "package.json")))
	{
		try
		{
			auto packageJson = fs.readText(chainPath(root, "package.json"));
			auto json = parseJSON(packageJson);
			if (seemsLikeDubJson(json))
				rootDub = true;
		}
		catch (Exception)
		{
		}
	}
	ret ~= RootSuggestion(root, rootDub);
	if (recursive)
	{
		PackageDescriptorLoop: foreach (pkg; tryDirEntries(root, "dub.{json,sdl}", fs.SpanMode.breadth))
		{
			auto dir = dirName(pkg);
			if (dir.canFind(".dub"))
				continue;
			if (dir == root)
				continue;
			if (blocked.any!(a => globMatch(dir.relativePath(root), a)
					|| globMatch(pkg.relativePath(root), a) || globMatch((dir ~ "/").relativePath, a)))
				continue;
			ret ~= RootSuggestion(dir, true);
		}
	}
	if (manyThreshold > 0 && ret.length >= manyThreshold)
	{
		switch (manyAction)
		{
		case ManyProjectsAction.ask:
			// TODO: translate
			auto loadButton = translate!"d.served.tooManySubprojects.load";
			auto skipButton = translate!"d.served.tooManySubprojects.skip";
			auto res = rpc.window.requestMessage(MessageType.warning,
					translate!"d.served.tooManySubprojects"(ret.length - manyThreshold + 1),
					[loadButton, skipButton]);
			if (res != loadButton)
				ret = ret[0 .. manyThreshold];
			break;
		case ManyProjectsAction.load:
			break;
		default:
			error("Ignoring invalid manyProjectsAction value ", manyAction, ", defaulting to skip");
			goto case;
		case ManyProjectsAction.skip:
			ret = ret[0 .. manyThreshold];
			break;
		}
	}
	foreach (dir; extra)
	{
		string p = buildNormalizedPath(root, dir);
		if (!ret.canFind!(a => a.dir == p))
			ret ~= RootSuggestion(p, fs.exists(chainPath(p, "dub.json"))
					|| fs.exists(chainPath(p, "dub.sdl")));
	}
	info("Root Suggestions: ", ret);
	return ret;
}

void doStartup(string workspaceUri)
{
	Workspace* proj = &workspace(workspaceUri);
	if (proj is &fallbackWorkspace)
	{
		error("Trying to do startup on unknown workspace ", workspaceUri, "?");
		return;
	}
	trace("Initializing serve-d for " ~ workspaceUri);

	struct Root
	{
		RootSuggestion root;
		string uri;
		WorkspaceD.Instance instance;
	}

	bool gotOneDub;
	scope roots = appender!(Root[]);

	foreach (root; rootsForProject(workspaceUri.uriToFile, proj.config.d.scanAllFolders,
			proj.config.d.disabledRootGlobs, proj.config.d.extraRoots,
			proj.config.d.manyProjectsAction, proj.config.d.manyProjectsThreshold))
	{
		info("Initializing instance for root ", root);
		StopWatch rootTimer;
		rootTimer.start();

		auto workspaceRoot = root.dir;
		workspaced.api.Configuration config;
		config.base = JSONValue([
				"dcd": JSONValue([
						"clientPath": JSONValue(proj.config.d.dcdClientPath.userPath),
						"serverPath": JSONValue(proj.config.d.dcdServerPath.userPath),
						"port": JSONValue(9166)
					]),
				"dmd": JSONValue(["path": JSONValue(proj.config.d.dmdPath.userPath)])
				]);
		auto instance = backend.addInstance(workspaceRoot, config);
		if (!activeInstance)
			activeInstance = instance;

		roots ~= Root(root, workspaceUri, instance);

		bool disableDub = proj.config.d.neverUseDub || !root.useDub;
		bool loadedDub;
		Exception err;
		if (!disableDub)
		{
			trace("Starting dub...");

			try
			{
				if (backend.attach(instance, "dub", err))
					loadedDub = true;
			}
			catch (Exception e)
			{
				err = e;
				loadedDub = false;
			}

			if (!loadedDub)
				error("Exception starting dub: ", err);
		}
		if (!loadedDub)
		{
			if (!disableDub)
			{
				error("Failed starting dub in ", root, " - falling back to fsworkspace");
				proj.startupError(workspaceRoot, translate!"d.ext.dubFail"(instance.cwd));
			}
			try
			{
				trace("Starting fsworkspace...");

				instance.config.set("fsworkspace", "additionalPaths",
						getPossibleSourceRoots(workspaceRoot));
				if (!backend.attach(instance, "fsworkspace", err))
					throw new Exception("Attach returned failure: " ~ err.msg);
			}
			catch (Exception e)
			{
				error(e);
				proj.startupError(workspaceRoot, translate!"d.ext.fsworkspaceFail"(instance.cwd));
			}
		}
		else
			gotOneDub = true;

		trace("Started files provider for root ", root);

		trace("Attaching dmd");
		if (!backend.attach(instance, "dmd", err))
			error("Failed to attach DMD component to ", workspaceUri, "\n", err.msg);
		prepareDCD(instance, workspaceUri);

		trace("Loaded Components for ", instance.cwd, ": ",
				instance.instanceComponents.map!"a.info.name");

		rootTimer.stop();
		info("Root ", root, " initialized in ", rootTimer.peek);
	}

	// TODO: lazy initialize dmd?
	trace("Starting auto completion service...");
	StopWatch dcdTimer;
	dcdTimer.start();
	foreach (root; roots.data)
		startDCDServer(root.instance, root.uri);
	dcdTimer.stop();
	trace("Started all completion servers in ", dcdTimer.peek);

	if (gotOneDub)
		setTimeout({ rpc.notifyMethod("coded/initDubTree"); }, 50);
}

void removeWorkspace(string workspaceUri)
{
	auto workspaceRoot = workspaceRootFor(workspaceUri);
	if (!workspaceRoot.length)
		return;
	backend.removeInstance(workspaceRoot);
	workspace(workspaceUri).disabled = true;
}

void handleBroadcast(WorkspaceD workspaced, WorkspaceD.Instance instance, JSONValue data)
{
	if (!instance)
		return;
	auto type = "type" in data;
	if (type && type.type == JSONType.string && type.str == "crash")
	{
		if (data["component"].str == "dcd")
			spawnFiber(() {
				prepareDCD(instance, instance.cwd.uriFromFile);
				startDCDServer(instance, instance.cwd.uriFromFile);
			});
	}
}

void prepareDCD(WorkspaceD.Instance instance, string workspaceUri)
{
	if (shutdownRequested)
		return;
	Workspace* proj = &workspace(workspaceUri, false);
	if (proj is &fallbackWorkspace)
	{
		error("Trying to start DCD on unknown workspace ", workspaceUri, "?");
		return;
	}
	if (!proj.config.d.enableAutoComplete)
	{
		return;
	}

	Exception err;
	string startupError;
	trace("Starting dcd");
	if (!backend.attach(instance, "dcd", err))
	{
		error("Failed to attach DCD component to ", instance.cwd, ": ", err.msg);
		if (dcdUpdating)
			return;
		else
			instance.config.set("dcd", "errorlog", instance.config.get("dcd",
					"errorlog", "") ~ "\n" ~ err.msg);
	}
	trace("Starting dcdext");
	if (!backend.attach(instance, "dcdext", err))
	{
		error("Failed to attach DCDExt component to ", instance.cwd, ": ", err.msg);
		instance.config.set("dcd", "errorlog", instance.config.get("dcd",
				"errorlog", "") ~ "\n" ~ err.msg);
	}
}

void startDCDServer(WorkspaceD.Instance instance, string workspaceUri)
{
	if (shutdownRequested || dcdUpdating)
		return;
	Workspace* proj = &workspace(workspaceUri, false);
	if (proj is &fallbackWorkspace)
	{
		error("Trying to start DCD on unknown workspace ", workspaceUri, "?");
		return;
	}
	if (!proj.config.d.enableAutoComplete)
	{
		return;
	}

	trace("Running DCD setup");
	try
	{
		trace("findAndSelectPort 9166");
		auto port = backend.get!DCDComponent(instance.cwd)
			.findAndSelectPort(cast(ushort) 9166).getYield;
		trace("Setting port to ", port);
		instance.config.set("dcd", "port", cast(int) port);
		auto stdlibPath = proj.stdlibPath;
		trace("startServer ", stdlibPath);
		backend.get!DCDComponent(instance.cwd).startServer(stdlibPath);
		trace("refreshImports");
		backend.get!DCDComponent(instance.cwd).refreshImports();
	}
	catch (Exception e)
	{
		rpc.window.showErrorMessage(translate!"d.ext.dcdFail"(instance.cwd,
				instance.config.get("dcd", "errorlog", "")));
		error(e);
		trace("Instance Config: ", instance.config);
		return;
	}
	info("Imports for ", instance.cwd, ": ", backend.getInstance(instance.cwd).importPaths);
}

string determineOutputFolder()
{
	import std.process : environment;

	version (linux)
	{
		if (fs.exists(buildPath(environment["HOME"], ".local", "share")))
			return buildPath(environment["HOME"], ".local", "share", "code-d", "bin");
		else
			return buildPath(environment["HOME"], ".code-d", "bin");
	}
	else version (Windows)
	{
		return buildPath(environment["APPDATA"], "code-d", "bin");
	}
	else
	{
		return buildPath(environment["HOME"], ".code-d", "bin");
	}
}

@protocolMethod("shutdown")
JSONValue shutdown()
{
	shutdownRequested = true;
	backend.shutdown();
	backend.destroy();
	served.extension.setTimeout({
		throw new Error("RPC still running 1s after shutdown");
	}, 1.seconds);
	return JSONValue(null);
}

public import served.commands.calltips;
public import served.commands.code_actions;
public import served.commands.code_lens;
public import served.commands.complete;
public import served.commands.dcd_update;
public import served.commands.definition;
public import served.commands.dub;
public import served.commands.format;
public import served.commands.symbol_search;
public import served.commands.file_search;

//dfmt off
alias members = AliasSeq!(
	__traits(derivedMembers, served.extension),
	__traits(derivedMembers, served.commands.calltips),
	__traits(derivedMembers, served.commands.code_actions),
	__traits(derivedMembers, served.commands.code_lens),
	__traits(derivedMembers, served.commands.complete),
	__traits(derivedMembers, served.commands.dcd_update),
	__traits(derivedMembers, served.commands.definition),
	__traits(derivedMembers, served.commands.dub),
	__traits(derivedMembers, served.commands.format),
	__traits(derivedMembers, served.commands.symbol_search),
	__traits(derivedMembers, served.commands.file_search)
);
//dfmt on

// === Protocol Notifications starting here ===

struct FileOpenInfo
{
	SysTime at;
}

__gshared FileOpenInfo[string] freshlyOpened;

@protocolNotification("workspace/didChangeWatchedFiles")
void onChangeFiles(DidChangeWatchedFilesParams params)
{
	foreach (change; params.changes)
	{
		string file = change.uri;
		if (change.type == FileChangeType.created && file.endsWith(".d"))
		{
			auto document = documents[file];
			auto isNew = file in freshlyOpened;
			info(file);
			if (isNew)
			{
				// Only edit if creation & opening is < 800msecs apart (vscode automatically opens on creation),
				// we don't want to affect creation from/in other programs/editors.
				if (Clock.currTime - isNew.at > 800.msecs)
				{
					freshlyOpened.remove(file);
					continue;
				}
				string workspace = workspaceRootFor(file);
				// Sending applyEdit so it is undoable
				auto patches = backend.get!ModulemanComponent(workspace)
					.normalizeModules(file.uriToFile, document.rawText);
				if (patches.length)
				{
					WorkspaceEdit edit;
					edit.changes[file] = patches.map!(a => TextEdit(TextRange(document.bytesToPosition(a.range[0]),
							document.bytesToPosition(a.range[1])), a.content)).array;
					rpc.sendMethod("workspace/applyEdit", ApplyWorkspaceEditParams(edit));
				}
			}
		}
	}
}

@protocolNotification("workspace/didChangeWorkspaceFolders")
void didChangeWorkspaceFolders(DidChangeWorkspaceFoldersParams params)
{
	foreach (toRemove; params.event.removed)
		removeWorkspace(toRemove.uri);
	foreach (toAdd; params.event.added)
	{
		workspaces ~= Workspace(toAdd);
		syncConfiguration(toAdd.uri);
		doStartup(toAdd.uri);
	}
}

@protocolNotification("textDocument/didOpen")
void onDidOpenDocument(DidOpenTextDocumentParams params)
{
	freshlyOpened[params.textDocument.uri] = FileOpenInfo(Clock.currTime);

	string lintSetting = config(params.textDocument.uri).d.lintOnFileOpen;
	bool shouldLint;
	if (lintSetting == "always")
		shouldLint = true;
	else if (lintSetting == "project")
		shouldLint = workspaceIndex(params.textDocument.uri) != size_t.max;

	if (shouldLint)
		onDidChangeDocument(DocumentLinkParams(TextDocumentIdentifier(params.textDocument.uri)));
}

@protocolNotification("textDocument/didClose")
void onDidCloseDocument(DidOpenTextDocumentParams params)
{
	// remove lint warnings for external projects
	if (workspaceIndex(params.textDocument.uri) == size_t.max)
	{
		import served.linters.diagnosticmanager : diagnostics, updateDiagnostics;

		foreach (ref coll; diagnostics)
			foreach (ref diag; coll)
				if (diag.uri == params.textDocument.uri)
					diag.diagnostics = null;

		updateDiagnostics(params.textDocument.uri);
	}
	// but keep warnings in local projects
}

int changeTimeout;
@protocolNotification("textDocument/didChange")
void onDidChangeDocument(DocumentLinkParams params)
{
	doDscanner(params);
}

@protocolNotification("coded/doDscanner")
void doDscanner(DocumentLinkParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return;
	auto d = config(params.textDocument.uri).d;
	if (!d.enableStaticLinting || !d.enableLinting)
		return;

	int delay = document.length > 50 * 1024 ? 1000 : 200; // be slower after 50KiB
	clearTimeout(changeTimeout);
	changeTimeout = setTimeout({
		import served.linters.dscanner;

		lint(document);
		// Delay to avoid too many requests
	}, delay);
}

@protocolNotification("textDocument/didSave")
void onDidSaveDocument(DidSaveTextDocumentParams params)
{
	import dub = served.commands.dub;

	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto config = workspace(params.textDocument.uri).config;
	auto document = documents[params.textDocument.uri];
	auto fileName = params.textDocument.uri.uriToFile.baseName;

	if (document.languageId == "d" || document.languageId == "diet")
	{
		if (!config.d.enableLinting)
			return;
		joinAll({
			if (config.d.enableStaticLinting)
			{
				if (document.languageId == "diet")
					return;
				import served.linters.dscanner;

				lint(document);
				clearTimeout(changeTimeout);
			}
		}, {
			if (backend.has!DubComponent(workspaceRoot) && config.d.enableDubLinting)
			{
				import served.linters.dub;

				lint(document);
			}
		});
	}
	else if (fileName == "dub.json" || fileName == "dub.sdl")
	{
		info("Updating dependencies");
		if (!backend.has!DubComponent(workspaceRoot))
		{
			Exception err;
			bool success = backend.attach(backend.getInstance(workspaceRoot), "dub", err);
			if (!success)
			{
				rpc.window.showMessage(MessageType.warning, translate!"d.ext.dubUpgradeFail");
				error(err);
			}
		}
		else
		{
			if (backend.get!DubComponent(workspaceRoot).isRunning)
				rpc.window.runOrMessage(backend.get!DubComponent(workspaceRoot)
						.upgrade(), MessageType.warning, translate!"d.ext.dubUpgradeFail");
		}

		setTimeout({
			const successfulUpdate = rpc.window.runOrMessage(backend.get!DubComponent(workspaceRoot)
				.updateImportPaths(true), MessageType.warning, translate!"d.ext.dubImportFail");
			if (successfulUpdate)
			{
				rpc.window.runOrMessage(dub.updateImports(), MessageType.warning,
					translate!"d.ext.dubImportFail");
			}
			else
			{
				try
				{
					dub.updateImports();
				}
				catch (Exception e)
				{
					errorf("Failed updating imports: %s", e);
				}
			}
		}, 500.msecs);

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
		}, 1.seconds);
		rpc.notifyMethod("coded/updateDubTree");
	}
}

shared static this()
{
	backend = new WorkspaceD();

	backend.onBroadcast = (&handleBroadcast).toDelegate;
	backend.onBindFail = (WorkspaceD.Instance instance, ComponentFactory factory, Exception err) {
		rpc.window.showErrorMessage(
				"Failed to load component " ~ factory.info.name ~ " for workspace "
				~ instance.cwd ~ "\n\nError: " ~ err.msg);
	};
}

shared static ~this()
{
	backend.shutdown();
}
