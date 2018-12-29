module served.extension;

import core.sync.mutex : Mutex;

import served.types;
import served.translate;
import served.fibermanager;

import core.time : Duration, msecs, seconds;

import std.algorithm : map, endsWith, canFind, any;
import std.array : array;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.datetime.systime : SysTime, Clock;
import std.experimental.logger;
import std.functional : toDelegate;
import std.json : JSONValue, JSON_TYPE, parseJSON;
import std.meta : AliasSeq;
import std.path : baseName, buildNormalizedPath, buildPath, chainPath, dirName, globMatch, relativePath;
import std.string : join;

import fs = std.file;
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

bool safe(alias fn, Args...)(Args args)
{
	try
	{
		fn(args);
		return true;
	}
	catch (Exception e)
	{
		error(e);
		return false;
	}
	catch (AssertError e)
	{
		error(e);
		return false;
	}
}

void changedConfig(string workspaceUri, string[] paths, served.types.Configuration config)
{
	StopWatch sw;
	sw.start();

	if (!syncedConfiguration)
	{
		syncedConfiguration = true;
		doGlobalStartup();
	}
	Workspace* proj = &workspace(workspaceUri);
	if (proj is &fallbackWorkspace)
	{
		error("Did not find workspace ", workspaceUri, " when updating config?");
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
				backend.get!DCDComponent(workspaceFs).addImports(config.stdlibPath);
			break;
		case "d.projectImportPaths":
			if (backend.has!DCDComponent(workspaceFs))
				backend.get!DCDComponent(workspaceFs).addImports(config.d.projectImportPaths);
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
					.setArchType(JSONValue(["arch-type" : JSONValue(config.d.dubArchType)])))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.archType"(config.d.dubArchType));
			break;
		case "d.dubBuildType":
			if (backend.has!DubComponent(workspaceFs) && config.d.dubBuildType.length
					&& !backend.get!DubComponent(workspaceFs)
					.setBuildType(JSONValue(["build-type" : JSONValue(config.d.dubBuildType)])))
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
					startDCD(backend.getInstance(workspaceFs), workspaceUri);
			}
			else if (backend.has!DCDComponent(workspaceFs))
			{
				backend.get!DCDComponent(workspaceFs).stopServer();
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

	if (capabilities.workspace.configuration && workspaces.length >= 2)
	{
		ConfigurationItem[] items;
		foreach (workspace; workspaces)
			foreach (section; configurationSections)
				items ~= ConfigurationItem(opt(workspace.folder.uri), opt(section));
		auto res = rpc.sendRequest("workspace/configuration", ConfigurationParams(items));
		if (res.result.type == JSON_TYPE.ARRAY)
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
				string[] changed;
				static foreach (n, section; configurationSections)
					changed ~= workspaces[i / configurationSections.length].config.replaceSection!section(
							settings[i + n].fromJSON!(configurationTypes[n]));
				changedConfig(workspaces[i / configurationSections.length].folder.uri,
						changed, workspaces[i / configurationSections.length].config);
			}
		}
	}
	else if (workspaces.length)
	{
		if (workspaces.length > 1)
			error(
					"Client does not support configuration request, only applying config for first workspace.");
		changedConfig(workspaces[0].folder.uri,
				workspaces[0].config.replace(configuration), workspaces[0].config);
	}
}

bool syncConfiguration(string workspaceUri)
{
	import painlessjson : fromJSON;

	if (capabilities.workspace.configuration)
	{
		Workspace* proj = &workspace(workspaceUri);
		if (proj is &fallbackWorkspace)
		{
			error("Did not find workspace ", workspaceUri, " when syncing config?");
			return false;
		}
		ConfigurationItem[] items;
		foreach (section; configurationSections)
			items ~= ConfigurationItem(opt(proj.folder.uri), opt(section));
		auto res = rpc.sendRequest("workspace/configuration", ConfigurationParams(items));
		if (res.result.type == JSON_TYPE.ARRAY)
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
			changedConfig(proj.folder.uri, changed, proj.config);
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
InitializeResult initialize(InitializeParams params)
{
	import std.file : chdir;

	capabilities = params.capabilities;
	trace("Set capabilities to ", params);

	if (params.workspaceFolders.length)
		workspaces = params.workspaceFolders.map!(a => Workspace(a,
				served.types.Configuration.init)).array;
	else if (params.rootUri.length)
		workspaces = [Workspace(WorkspaceFolder(params.rootUri, "Root"),
				served.types.Configuration.init)];
	else if (params.rootPath.length)
		workspaces = [Workspace(WorkspaceFolder(params.rootPath.uriFromFile,
				"Root"), served.types.Configuration.init)];
	if (workspaces.length)
	{
		fallbackWorkspace.folder = workspaces[0].folder;
		fallbackWorkspace.initialized = true;
	}

	InitializeResult result;
	result.capabilities.textDocumentSync = documents.syncKind;
	result.capabilities.completionProvider = CompletionOptions(false, [".", "(", "[", "="]);
	result.capabilities.signatureHelpProvider = SignatureHelpOptions(["(", "[", ","]);
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
		if (!syncedConfiguration && capabilities.workspace.configuration)
			foreach (ref workspace; workspaces)
				syncConfiguration(workspace.folder.uri);
	}, 1000);

	return result;
}

void doGlobalStartup()
{
	try
	{
		trace("Initializing serve-d for global access");

		backend.globalConfiguration.base = JSONValue(["dcd" : JSONValue(["clientPath"
				: JSONValue(firstConfig.d.dcdClientPath), "serverPath"
				: JSONValue(firstConfig.d.dcdServerPath), "port" : JSONValue(9166)]),
				"dmd" : JSONValue(["path" : JSONValue(firstConfig.d.dmdPath)])]);

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
			info("DCD is outdated.");
			dcdUpdating = true;
			if (firstConfig.d.aggressiveUpdate)
				spawnFiber((&updateDCD).toDelegate);
			else
			{
				spawnFiber({
					version (DCDFromSource)
						auto action = translate!"d.ext.compileProgram"("DCD");
					else
						auto action = translate!"d.ext.downloadProgram"("DCD");

					auto installed = backend.has!DCDComponent
						? backend.get!DCDComponent.clientInstalledVersion : "none";

					auto res = rpc.window.requestMessage(MessageType.error,
						translate!"d.served.outdatedDCD"(DCDComponent.latestKnownVersion.to!(string[])
						.join("."), installed), [action]);

					if (res == action)
						spawnFiber((&updateDCD).toDelegate);
				});
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
		auto packageJson = fs.readText(chainPath(root, "package.json"));
		try
		{
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
		PackageDescriptorLoop: foreach (pkg; fs.dirEntries(root, "dub.{json,sdl}", fs.SpanMode.breadth))
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
			auto res = rpc.window.requestMessage(MessageType.warning, "There are too many subprojects in this project according to d.manyProjectsThreshold\n\nDo you want to load additional " ~ (
					ret.length - manyThreshold + 1).to!string ~ " total projects?", ["Load", "Skip"]);
			if (res != "Load")
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

	foreach (root; rootsForProject(workspaceUri.uriToFile, proj.config.d.scanAllFolders,
			proj.config.d.disabledRootGlobs, proj.config.d.extraRoots,
			proj.config.d.manyProjectsAction, proj.config.d.manyProjectsThreshold))
	{
		auto workspaceRoot = root.dir;
		workspaced.api.Configuration config;
		config.base = JSONValue(["dcd" : JSONValue(["clientPath"
				: JSONValue(proj.config.d.dcdClientPath), "serverPath"
				: JSONValue(proj.config.d.dcdServerPath), "port" : JSONValue(9166)]),
				"dmd" : JSONValue(["path" : JSONValue(proj.config.d.dmdPath)])]);
		auto instance = backend.addInstance(workspaceRoot, config);

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
			setTimeout({ rpc.notifyMethod("coded/initDubTree"); }, 50);

		if (!backend.attach(instance, "dmd", err))
			error("Failed to attach DMD component to ", workspaceUri, "\n", err.msg);
		startDCD(instance, workspaceUri);

		trace("Loaded Components for ", instance.cwd, ": ",
				instance.instanceComponents.map!"a.info.name");
	}
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
	if (type && type.type == JSON_TYPE.STRING && type.str == "crash")
	{
		if (data["component"].str == "dcd")
			spawnFiber(() => startDCD(instance, instance.cwd.uriFromFile));
	}
}

void startDCD(WorkspaceD.Instance instance, string workspaceUri)
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
			startupError ~= "\n" ~ err.msg;
	}
	trace("Starting dcdext");
	if (!backend.attach(instance, "dcdext", err))
	{
		error("Failed to attach DCDExt component to ", instance.cwd, ": ", err.msg);
		startupError ~= "\n" ~ err.msg;
	}
	trace("Running DCD setup");
	try
	{
		trace("findAndSelectPort 9166");
		auto port = backend.get!DCDComponent(instance.cwd)
			.findAndSelectPort(cast(ushort) 9166).getYield;
		trace("Setting port to ", port);
		instance.config.set("dcd", "port", cast(int) port);
		trace("startServer ", proj.config.stdlibPath);
		backend.get!DCDComponent(instance.cwd).startServer(proj.config.stdlibPath);
		trace("refreshImports");
		backend.get!DCDComponent(instance.cwd).refreshImports();
	}
	catch (Exception e)
	{
		rpc.window.showErrorMessage(translate!"d.ext.dcdFail"(instance.cwd, startupError));
		error(e);
		trace("Instance Config: ", instance.config);
		return;
	}
	info("Imports for ", instance.cwd, ": ", backend.getInstance(instance.cwd).importPaths);

	auto globalDCD = backend.has!DCDComponent ? backend.get!DCDComponent : null;
	if (globalDCD && !globalDCD.isActive)
	{
		globalDCD.fromRunning(globalDCD.getSupportsFullOutput, globalDCD.isUsingUnixDomainSockets
				? globalDCD.getSocketFile : "", globalDCD.isUsingUnixDomainSockets ? 0
				: globalDCD.getRunningPort);
	}
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
					.normalizeModules(file.uriToFile, document.text);
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
}

int changeTimeout;
@protocolNotification("textDocument/didChange")
void onDidChangeDocument(DocumentLinkParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return;
	int delay = document.text.length > 50 * 1024 ? 1000 : 200; // be slower after 50KiB
	clearTimeout(changeTimeout);
	changeTimeout = setTimeout({
		import served.linters.dscanner;

		lint(document);
		// Delay to avoid too many requests
	}, delay);
}

@protocolNotification("coded/doDscanner")
void doDscanner(DocumentLinkParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return;
	int delay = document.text.length > 50 * 1024 ? 1000 : 200; // be slower after 50KiB
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
			rpc.window.runOrMessage(backend.get!DubComponent(workspaceRoot)
				.updateImportPaths(true), MessageType.warning, translate!"d.ext.dubImportFail");
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

struct Timeout
{
	StopWatch sw;
	Duration timeout;
	void delegate() callback;
	int id;
}

int setTimeout(void delegate() callback, int ms)
{
	return setTimeout(callback, ms.msecs);
}

void setImmediate(void delegate() callback)
{
	setTimeout(callback, 0);
}

int setTimeout(void delegate() callback, Duration timeout)
{
	trace("Setting timeout for ", timeout);
	Timeout to;
	to.timeout = timeout;
	to.callback = callback;
	to.sw.start();
	to.id = ++timeoutID;
	synchronized (timeoutsMutex)
		timeouts ~= to;
	return to.id;
}

void clearTimeout(int id)
{
	synchronized (timeoutsMutex)
		foreach_reverse (i, ref timeout; timeouts)
		{
			if (timeout.id == id)
			{
				timeout.sw.stop();
				if (timeouts.length > 1)
					timeouts[i] = timeouts[$ - 1];
				timeouts.length--;
				return;
			}
		}
}

__gshared void delegate(void delegate()) spawnFiber;

shared static this()
{
	spawnFiber = (&setImmediate).toDelegate;
	backend = new WorkspaceD();

	backend.onBroadcast = (&handleBroadcast).toDelegate;
	backend.onBindFail = (WorkspaceD.Instance instance, ComponentFactory factory, Exception err) {
		rpc.window.showErrorMessage(
				"Failed to load component " ~ factory.info.name ~ " for workspace "
				~ instance.cwd ~ "\n\nError: " ~ err.msg);
	};
}

__gshared int timeoutID;
__gshared Timeout[] timeouts;
__gshared Mutex timeoutsMutex;

// Called at most 100x per second
void parallelMain()
{
	timeoutsMutex = new Mutex;
	while (true)
	{
		synchronized (timeoutsMutex)
			foreach_reverse (i, ref timeout; timeouts)
			{
				if (timeout.sw.peek >= timeout.timeout)
				{
					timeout.sw.stop();
					timeout.callback();
					trace("Calling timeout");
					if (timeouts.length > 1)
						timeouts[i] = timeouts[$ - 1];
					timeouts.length--;
				}
			}
		Fiber.yield();
	}
}
