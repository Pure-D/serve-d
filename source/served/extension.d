module served.extension;

import served.io.nothrow_fs;
import served.types;
import served.utils.fibermanager;
import served.utils.progress;
import served.utils.translate;

public import served.utils.async;

import core.time : msecs, seconds;

import std.algorithm : any, canFind, endsWith, map;
import std.array : appender, array;
import std.conv : text, to;
import std.datetime.stopwatch : StopWatch;
import std.datetime.systime : Clock, SysTime;
import std.experimental.logger;
import std.format : format;
import std.functional : toDelegate;
import std.meta : AliasSeq;
import std.path : baseName, buildNormalizedPath, buildPath, chainPath, dirName,
	globMatch, relativePath;
import std.string : join;

import io = std.stdio;

import workspaced.api;
import workspaced.api : WConfiguration = Configuration;
import workspaced.coms;

// list of all commands for auto dispatch
public import served.commands.calltips;
public import served.commands.code_actions;
public import served.commands.code_lens;
public import served.commands.color;
public import served.commands.complete;
public import served.commands.dcd_update;
public import served.commands.definition;
public import served.commands.dub;
public import served.commands.file_search;
public import served.commands.format;
public import served.commands.highlight;
public import served.commands.symbol_search;
public import served.commands.test_provider;
public import served.workers.profilegc;
public import served.workers.rename_listener;

//dfmt off
alias members = AliasSeq!(
	__traits(derivedMembers, served.extension),
	__traits(derivedMembers, served.commands.calltips),
	__traits(derivedMembers, served.commands.code_actions),
	__traits(derivedMembers, served.commands.code_lens),
	__traits(derivedMembers, served.commands.color),
	__traits(derivedMembers, served.commands.complete),
	__traits(derivedMembers, served.commands.dcd_update),
	__traits(derivedMembers, served.commands.definition),
	__traits(derivedMembers, served.commands.dub),
	__traits(derivedMembers, served.commands.file_search),
	__traits(derivedMembers, served.commands.format),
	__traits(derivedMembers, served.commands.highlight),
	__traits(derivedMembers, served.commands.symbol_search),
	__traits(derivedMembers, served.commands.test_provider),
	__traits(derivedMembers, served.workers.profilegc),
	__traits(derivedMembers, served.workers.rename_listener),
);
//dfmt on

/// Set to true when shutdown is called
__gshared bool shutdownRequested;

void changedConfig(string workspaceUri, string[] paths, served.types.Configuration config,
		bool allowFallback = false, size_t index = 0, size_t numConfigs = 0)
{
	StopWatch sw;
	sw.start();

	reportProgress(ProgressType.configLoad, index, numConfigs, workspaceUri);

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
		ensureStartedUp();
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
				&& !backend.get!DubComponent(workspaceFs).setArchType(config.d.dubArchType))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.archType"(config.d.dubArchType));
			break;
		case "d.dubBuildType":
			if (backend.has!DubComponent(workspaceFs) && config.d.dubBuildType.length
				&& !backend.get!DubComponent(workspaceFs).setBuildType(config.d.dubBuildType))
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
					lazyStartDCDServer(instance, workspaceUri);
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

@protocolNotification("workspace/didChangeConfiguration")
void didChangeConfiguration(DidChangeConfigurationParams params)
{
	processConfigChange(params.settings.parseConfiguration);
}

void processConfigChange(served.types.Configuration configuration)
{
	syncingConfiguration = true;
	scope (exit)
		syncingConfiguration = false;

	if (!workspaces.length)
	{
		info("initializing config for temporary fallback workspace");
		workspaces = [fallbackWorkspace];
		workspaces[0].initialized = false;
	}

	if (capabilities
		.workspace.orDefault
		.configuration.orDefault
		&& workspaces.length >= 2)
	{
		ConfigurationItem[] items;
		items = getGlobalConfigurationItems(); // default workspace
		const stride = configurationSections.length;

		foreach (workspace; workspaces)
			items ~= getConfigurationItems(workspace.folder.uri);

		trace("Re-requesting configuration from client because there is more than 1 workspace");
		auto res = rpc.sendRequest("workspace/configuration", ConfigurationParams(items));

		const expected = workspaces.length + 1;
		string[] settings = res.validateConfigurationItemsResponse(expected);
		if (!settings.length)
			return;

		for (size_t i = 0; i < expected; i++)
		{
			const isDefault = i == 0;
			auto workspace = isDefault ? &fallbackWorkspace : &.workspace(items[i * stride].scopeUri.deref,
					false);
			string[] changed = workspace.config.replaceAllSectionsJson(settings[i * stride .. $]);
			changedConfig(isDefault ? null : workspace.folder.uri, changed,
					workspace.config, isDefault, i, expected);
		}
	}
	else if (workspaces.length)
	{
		if (workspaces.length > 1)
			error(
					"Client does not support configuration request, only applying config for first workspace.");
		auto changed = workspaces[0].config.replace(configuration);
		changedConfig(workspaces[0].folder.uri, changed, workspaces[0].config, false, 0, 1);
		fallbackWorkspace.config = workspaces[0].config;
	}
	else
		error("unexpected state: got ", workspaces.length, " workspaces and ",
				capabilities
					.workspace.orDefault
					.configuration.orDefault ? "" : "no ",
				"configuration request support");
	reportProgress(ProgressType.configFinish, 0, 0);
}

bool syncConfiguration(string workspaceUri, size_t index = 0, size_t numConfigs = 0)
{
	if (capabilities
		.workspace.orDefault
		.configuration.orDefault)
	{
		Workspace* proj = &workspace(workspaceUri);
		if (proj is &fallbackWorkspace && workspaceUri.length)
		{
			error("Did not find workspace ", workspaceUri, " when syncing config?");
			return false;
		}

		ConfigurationItem[] items;
		if (workspaceUri.length)
			items = getConfigurationItems(proj.folder.uri);
		else
			items = getGlobalConfigurationItems();

		trace("Sending workspace/configuration request for ", workspaceUri);
		auto res = rpc.sendRequest("workspace/configuration", ConfigurationParams(items));

		string[] settings = res.validateConfigurationItemsResponse();
		if (!settings.length)
			return false;

		string[] changed = proj.config.replaceAllSectionsJson(settings);
		string uri = workspaceUri.length ? proj.folder.uri : null;
		changedConfig(uri, changed, proj.config,
				workspaceUri.length == 0, index, numConfigs);
		return true;
	}
	else
		return false;
}

ConfigurationItem[] getGlobalConfigurationItems()
{
	ConfigurationItem[] items = new ConfigurationItem[configurationSections.length];
	foreach (i, section; configurationSections)
		items[i] = ConfigurationItem(Optional!string.init, opt(section));
	return items;
}

ConfigurationItem[] getConfigurationItems(DocumentUri uri)
{
	ConfigurationItem[] items = new ConfigurationItem[configurationSections.length];
	foreach (i, section; configurationSections)
		items[i] = ConfigurationItem(opt(uri), opt(section));
	return items;
}

private string[] validateConfigurationItemsResponse(scope return ref ResponseMessageRaw res,
		size_t expected = size_t.max)
{
	if (!res.resultJson.looksLikeJsonArray)
	{
		error("Got invalid configuration response from language client. (not an array)");
		trace("Response: ", res);
		return null;
	}

	string[] settings;
	int i;
	res.resultJson.visitJsonArray!(v => i++);
	settings.length = i;
	i = 0;
	res.resultJson.visitJsonArray!(v => settings[i++] = v);

	if (settings.length % configurationSections.length != 0)
	{
		error("Got invalid configuration response from language client. (invalid length)");
		trace("Response: ", res);
		return null;
	}
	if (expected != size_t.max)
	{
		auto total = settings.length / configurationSections.length;
		if (total > expected)
		{
			warning("Loading different amount of workspaces than requested: requested ",
					expected, " but loading ", total);
		}
		else if (total < expected)
		{
			error("Didn't get all configs we asked for: requested ", expected, " but loading ", total);
			return null;
		}
	}
	return settings;
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
__gshared bool startedUp = false;
InitializeResult initialize(InitializeParams params)
{
	import served.info;
	import std.file : chdir;

	if (params.trace == "verbose")
		globalLogLevel = LogLevel.trace;

	capabilities = params.capabilities;
	trace("initialize params:");
	prettyPrintStruct!trace(params);

	// need to use 2 .get on workspaceFolders because it's an Optional!(Nullable!(T[]))
	if (params.workspaceFolders.isSet
		&& !params.workspaceFolders.get.isNull
		&& params.workspaceFolders.get.get.length > 0
	)
		workspaces = params.workspaceFolders.get.get
			.map!(a => Workspace(a, served.types.Configuration.init))
			.array;
	else if (params.rootUri.length)
		workspaces = [
			Workspace(WorkspaceFolder(params.rootUri, "Root"), served.types.Configuration.init)
		];
	else if (params.rootPath.orDefault.length)
		workspaces = [
			Workspace(WorkspaceFolder(params.rootPath.deref.uriFromFile, "Root"),
					served.types.Configuration.init)
		];

	if (workspaces.length)
	{
		fallbackWorkspace.folder = workspaces[0].folder;
		fallbackWorkspace.initialized = true;
	}
	else
	{
		import std.path : buildPath;
		import std.file : tempDir, exists, mkdir;

		auto tmpFolder = buildPath(tempDir, "serve-d-dummy-workspace");
		if (!tmpFolder.exists)
			mkdir(tmpFolder);
		fallbackWorkspace.folder = WorkspaceFolder(tmpFolder.uriFromFile, "serve-d dummy tmp folder");
		fallbackWorkspace.initialized = true;
	}

	InitializeResult result;
	CompletionOptions completionProvider = {
		resolveProvider: doCompleteSnippets,
		triggerCharacters: [
			".", "=", "/", "*", "+", "-"
		],
		completionItem: CompletionOptions.CompletionItem(true.opt)
	};
	SignatureHelpOptions signatureHelpProvider = {
		triggerCharacters: ["(", "[", ","]
	};
	CodeLensOptions codeLensProvider = {
		resolveProvider: true
	};
	WorkspaceFoldersServerCapabilities workspaceFolderCapabilities = {
		supported: true,
		changeNotifications: true
	};
	ServerWorkspaceCapabilities workspaceCapabilities = {
		workspaceFolders: workspaceFolderCapabilities
	};
	ServerCapabilities serverCapabilities = {
		textDocumentSync: documents.syncKind,
		// only provide fixes when doCompleteSnippets is requested
		completionProvider: completionProvider,
		signatureHelpProvider: signatureHelpProvider,
		workspaceSymbolProvider: true,
		definitionProvider: true,
		hoverProvider: true,
		codeActionProvider: true,
		codeLensProvider: codeLensProvider,
		documentSymbolProvider: true,
		documentFormattingProvider: true,
		documentRangeFormattingProvider: true,
		colorProvider: DocumentColorOptions.init,
		documentHighlightProvider: true,
		workspace: workspaceCapabilities
	};
	result.capabilities = serverCapabilities;

	version (unittest) {}
	else
	{
		// only included in non-test builds, because served.info is excluded from the unittest configurations
		ServerInfo serverInfo = {
			name: "serve-d",
			version_: format!"v%(%s.%)%s"(Version,
				VersionSuffix.length ? text('-', VersionSuffix) : VersionSuffix)
		};
		result.serverInfo = serverInfo;
	}

	setTimeout({
		if (!syncedConfiguration && !syncingConfiguration)
		{
			if (capabilities
				.workspace.orDefault
				.configuration.orDefault)
			{
				if (!syncConfiguration(null, 0, workspaces.length + 1))
					error("Syncing user configuration failed!");

				warning(
					"Didn't receive any configuration notification, manually requesting all configurations now");

				foreach (i, ref workspace; workspaces)
					syncConfiguration(workspace.folder.uri, i + 1, workspaces.length + 1);
			}
			else
			{
				warning("This Language Client doesn't support configuration requests and also didn't send any ",
					"configuration to serve-d. Initializing using default configuration");

				changedConfig(workspaces[0].folder.uri, null, workspaces[0].config);
				fallbackWorkspace.config = workspaces[0].config;
			}

			reportProgress(ProgressType.configFinish, 0, 0);
		}
	}, 1000);

	return result;
}

void ensureStartedUp()
{
	if (startedUp)
		return;
	startedUp = true;
	doGlobalStartup();
}

void doGlobalStartup()
{
	import workspaced.backend : Configuration;

	try
	{
		trace("Initializing serve-d for global access");

		backend.globalConfiguration.base = [
			"dcd": Configuration.Section([
				"clientPath": Configuration.ValueT(firstConfig.d.dcdClientPath.userPath),
				"serverPath": Configuration.ValueT(firstConfig.d.dcdServerPath.userPath),
				"port": Configuration.ValueT(9166)
			]),
			"dmd": Configuration.Section([
				"path": Configuration.ValueT(firstConfig.d.dmdPath.userPath)
			])
		];

		trace("Setup global configuration as " ~ backend.globalConfiguration.base.to!string);

		reportProgress(ProgressType.globalStartup, 0, 0, "Initializing serve-d...");

		trace("Registering dub");
		backend.register!DubComponent(false);
		trace("Registering fsworkspace");
		backend.register!FSWorkspaceComponent(false);
		trace("Registering dcd");
		backend.register!DCDComponent;
		trace("Registering dcdext");
		backend.register!DCDExtComponent;
		trace("Registering dmd");
		backend.register!DMDComponent;
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
		trace("Starting snippets");
		backend.register!SnippetsComponent;

		if (!backend.has!DCDComponent || backend.get!DCDComponent.isOutdated)
		{
			auto installed = backend.has!DCDComponent
				? backend.get!DCDComponent.serverInstalledVersion : "none";

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
					string action;
					if (isDCDFromSource)
						action = translate!"d.ext.compileProgram"("DCD");
					else
						action = translate!"d.ext.downloadProgram"("DCD");

					auto res = rpc.window.requestMessage(MessageType.error, outdatedMessage, [
							action
						]);

					if (res == action)
						spawnFiber((&updateDCD).toDelegate);
				}, 4);
			}
		}

		cast(void)emitExtensionEvent!onRegisteredComponents;
	}
	catch (Exception e)
	{
		error("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
		error("Failed to fully globally initialize:");
		error(e);
		error("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
	}
}

/// A root which could be started up on load
struct RootSuggestion
{
	/// Absolute filesystem path to the project root (assuming passed in root was absolute)
	string dir;
	///
	bool useDub;
}

RootSuggestion[] rootsForProject(string root, bool recursive, string[] blocked,
		string[] extra)
{
	RootSuggestion[] ret;
	void addSuggestion(string dir, bool useDub)
	{
		dir = buildNormalizedPath(dir);

		if (dir.endsWith('/', '\\'))
			dir = dir[0 .. $ - 1];

		if (!ret.canFind!(a => a.dir == dir))
			ret ~= RootSuggestion(dir, useDub);
	}

	bool rootDub = fs.exists(chainPath(root, "dub.json")) || fs.exists(chainPath(root, "dub.sdl"));
	if (!rootDub && fs.exists(chainPath(root, "package.json")))
	{
		try
		{
			auto packageJson = fs.readText(chainPath(root, "package.json"));
			if (seemsLikeDubJson(packageJson))
				rootDub = true;
		}
		catch (Exception)
		{
		}
	}
	addSuggestion(root, rootDub);

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
			addSuggestion(dir, true);
		}
	}
	foreach (dir; extra)
	{
		string p = buildNormalizedPath(root, dir);
		addSuggestion(p, fs.exists(chainPath(p, "dub.json")) || fs.exists(chainPath(p, "dub.sdl")));
	}
	info("Root Suggestions: ", ret);
	return ret;
}

void doStartup(string workspaceUri)
{
	ensureStartedUp();

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

	auto rootSuggestions = rootsForProject(workspaceUri.uriToFile, proj.config.d.scanAllFolders,
			proj.config.d.disabledRootGlobs, proj.config.d.extraRoots);

	foreach (i, root; rootSuggestions)
	{
		reportProgress(ProgressType.workspaceStartup, i, rootSuggestions.length, root.dir.uriFromFile);
		info("registering instance for root ", root);

		auto workspaceRoot = root.dir;
		WConfiguration config;
		config.base = [
			"dcd": WConfiguration.Section([
				"clientPath": WConfiguration.ValueT(proj.config.d.dcdClientPath.userPath),
				"serverPath": WConfiguration.ValueT(proj.config.d.dcdServerPath.userPath),
				"port": WConfiguration.ValueT(9166)
			]),
			"dmd": WConfiguration.Section([
				"path": WConfiguration.ValueT(proj.config.d.dmdPath.userPath)
			])
		];
		auto instance = backend.addInstance(workspaceRoot, config);
		if (!activeInstance)
			activeInstance = instance;

		roots ~= Root(root, workspaceUri, instance);
		emitExtensionEvent!onProjectAvailable(instance, workspaceRoot, workspaceUri);

		if (auto lazyInstance = cast(LazyWorkspaceD.LazyInstance)instance)
		{
			auto lazyLoadCallback(WorkspaceD.Instance instance, string workspaceRoot, string workspaceUri, RootSuggestion root)
			{
				return () => delayedProjectActivation(instance, workspaceRoot, workspaceUri, root);
			}

			lazyInstance.onLazyLoadInstance(lazyLoadCallback(instance, workspaceRoot, workspaceUri, root));
		}
		else
		{
			delayedProjectActivation(instance, workspaceRoot, workspaceUri, root);
		}
	}

	trace("Starting auto completion service...");
	StopWatch dcdTimer;
	dcdTimer.start();
	foreach (i, root; roots.data)
	{
		reportProgress(ProgressType.completionStartup, i, roots.data.length,
				root.instance.cwd.uriFromFile);

		lazyStartDCDServer(root.instance, root.uri);
	}
	dcdTimer.stop();
	trace("Started all completion servers in ", dcdTimer.peek);
}

shared int totalLoadedProjects;
void delayedProjectActivation(WorkspaceD.Instance instance, string workspaceRoot, string workspaceUri, RootSuggestion root)
{
	import core.atomic;

	Workspace* proj = &workspace(workspaceUri);
	if (proj is &fallbackWorkspace)
	{
		error("Trying to do startup on unknown workspace ", root.dir, "?");
		throw new Exception("failed project instance startup for " ~ root.dir);
	}

	auto numLoaded = atomicOp!"+="(totalLoadedProjects, 1);

	auto manyProjectsAction = cast(ManyProjectsAction) proj.config.d.manyProjectsAction;
	auto manyThreshold = proj.config.d.manyProjectsThreshold;
	if (manyThreshold > 0 && numLoaded > manyThreshold)
	{
		switch (manyProjectsAction)
		{
		case ManyProjectsAction.ask:
			auto loadButton = translate!"d.served.tooManySubprojects.load";
			auto skipButton = translate!"d.served.tooManySubprojects.skip";
			auto res = rpc.window.requestMessage(MessageType.warning,
					translate!"d.served.tooManySubprojects.path"(root.dir),
					[loadButton, skipButton]);
			if (res != loadButton)
				goto case ManyProjectsAction.skip;
			break;
		case ManyProjectsAction.load:
			break;
		default:
			error("Ignoring invalid manyProjectsAction value ", manyProjectsAction, ", defaulting to skip");
			goto case;
		case ManyProjectsAction.skip:
			backend.removeInstance(workspaceRoot);
			throw new Exception("skipping load of this instance");
		}
	}

	info("Initializing instance for root ", root);
	StopWatch rootTimer;
	rootTimer.start();

	emitExtensionEvent!onAddingProject(instance, workspaceRoot, workspaceUri);

	bool disableDub = proj.config.d.neverUseDub || !root.useDub;
	bool loadedDub;
	Exception err;
	if (!disableDub)
	{
		trace("Starting dub...");
		reportProgress(ProgressType.dubReload, 0, 1, workspaceUri);
		scope (exit)
			reportProgress(ProgressType.dubReload, 1, 1, workspaceUri);

		try
		{
			if (backend.attachEager(instance, "dub", err))
			{
				scope (failure)
					instance.detach!DubComponent;

				instance.get!DubComponent.validateConfiguration();
				loadedDub = true;
			}
		}
		catch (Exception e)
		{
			err = e;
			loadedDub = false;
		}

		if (!loadedDub)
			error("Exception starting dub: ", err);
		else
			trace("Started dub with root dependencies ", instance.get!DubComponent.rootDependencies);
	}
	if (!loadedDub)
	{
		if (!disableDub)
		{
			error("Failed starting dub in ", root, " - falling back to fsworkspace");
			proj.startupError(workspaceRoot, translate!"d.ext.dubFail"(instance.cwd, err ? err.msg : ""));
		}
		try
		{
			trace("Starting fsworkspace...");

			instance.config.set("fsworkspace", "additionalPaths",
					getPossibleSourceRoots(workspaceRoot));
			if (!backend.attachEager(instance, "fsworkspace", err))
				throw new Exception("Attach returned failure: " ~ err.msg);
		}
		catch (Exception e)
		{
			error(e);
			proj.startupError(workspaceRoot, translate!"d.ext.fsworkspaceFail"(instance.cwd));
		}
	}
	else
		didLoadDubProject();

	trace("Started files provider for root ", root);

	trace("Loaded Components for ", instance.cwd, ": ",
			instance.instanceComponents.map!"a.info.name");

	emitExtensionEvent!onAddedProject(instance, workspaceRoot, workspaceUri);

	rootTimer.stop();
	info("Root ", root, " initialized in ", rootTimer.peek);
}

void didLoadDubProject()
{
	static bool loadedDub = false;
	if (!loadedDub)
	{
		loadedDub = true;
		setTimeout({ rpc.notifyMethod("coded/initDubTree"); }, 50);
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

class MessageHandler : IMessageHandler
{
	void warn(WorkspaceD.Instance instance, string component,
		int id, string message, string details = null)
	{
		
	}

	void error(WorkspaceD.Instance instance, string component,
		int id, string message, string details = null)
	{
		
	}

	void handleCrash(WorkspaceD.Instance instance, string component,
		ComponentWrapper componentInstance)
	{
		if (component == "dcd")
		{
			spawnFiber(() {
				startDCDServer(instance, instance.cwd.uriFromFile);
			});
		}
	}
}

bool wantsDCDServer(string workspaceUri)
{
	if (shutdownRequested || dcdUpdating)
		return false;
	Workspace* proj = &workspace(workspaceUri, false);
	if (proj is &fallbackWorkspace)
	{
		error("Trying to access DCD on unknown workspace ", workspaceUri, "?");
		return false;
	}
	if (!proj.config.d.enableAutoComplete)
	{
		return false;
	}

	return true;
}

void startDCDServer(WorkspaceD.Instance instance, string workspaceUri)
{
	if (!wantsDCDServer(workspaceUri))
		return;
	Workspace* proj = &workspace(workspaceUri, false);
	assert(proj, "project unloaded while starting DCD?!");

	trace("Running DCD setup");
	try
	{
		auto dcd = instance.get!DCDComponent;
		auto stdlibPath = proj.stdlibPath;
		trace("startServer ", stdlibPath);
		dcd.startServer(stdlibPath, false, true);
		trace("refreshImports");
		dcd.refreshImports();
	}
	catch (Exception e)
	{
		rpc.window.showErrorMessage(translate!"d.ext.dcdFail"(instance.cwd,
				instance.config.get("dcd", "errorlog", "")));
		error(e);
		trace("Instance Config: ", instance.config);
		return;
	}
	info("Imports for ", instance.cwd, ": ", instance.importPaths);
}

void lazyStartDCDServer(WorkspaceD.Instance instance, string workspaceUri)
{
	auto lazyInstance = cast(LazyWorkspaceD.LazyInstance)instance;
	if (lazyInstance)
	{
		lazyInstance.onLazyLoad("dcd", delegate() nothrow {
			try
			{
				reportProgress(ProgressType.importReload, 0, 1, workspaceUri);
				scope (exit)
					reportProgress(ProgressType.importReload, 1, 1, workspaceUri);
				startDCDServer(instance, workspaceUri);
			}
			catch (Exception e)
			{
				try
				{
					error("Failed loading DCD on demand: ", e);
				}
				catch (Exception)
				{
				}
			}
		});
	}
	else
		startDCDServer(instance, workspaceUri);
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
JsonValue shutdown()
{
	if (!backend)
		return JsonValue(null);
	backend.shutdown();
	served.extension.setTimeout({
		throw new Error("RPC still running 1s after shutdown");
	}, 1.seconds);
	return JsonValue(null);
}

// === Protocol Notifications starting here ===

@protocolNotification("$/setTrace")
void setTrace(TraceParams params)
{
	if (params.value == "verbose")
		globalLogLevel = LogLevel.trace;
	else
		globalLogLevel = LogLevel.info;
}

@protocolNotification("workspace/didChangeWorkspaceFolders")
void didChangeWorkspaceFolders(DidChangeWorkspaceFoldersParams params)
{
	foreach (toRemove; params.event.removed)
		removeWorkspace(toRemove.uri);
	foreach (i, toAdd; params.event.added)
	{
		workspaces ~= Workspace(toAdd);
		syncConfiguration(toAdd.uri, i, params.event.added.length);
		doStartup(toAdd.uri);
	}
}

@protocolNotification("textDocument/didOpen")
void onDidOpenDocument(DidOpenTextDocumentParams params)
{
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
void onDidCloseDocument(DidCloseTextDocumentParams params)
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

int genericChangeTimeout;
@protocolNotification("textDocument/didChange")
void onDidChangeDocument(DocumentLinkParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.getLanguageId != "d")
		return;

	doDscanner(params);

	int delay = document.length > 50 * 1024 ? 500 : 50; // be slower after 50KiB
	clearTimeout(genericChangeTimeout);
	genericChangeTimeout = setTimeout({
		import served.linters.dfmt : lint;

		lint(document);
		// Delay to avoid too many requests
	}, delay);
}

int dscannerChangeTimeout;
@protocolNotification("coded/doDscanner")  // deprecated alias
@protocolNotification("served/doDscanner")
void doDscanner(DocumentLinkParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.getLanguageId != "d")
		return;
	auto d = config(params.textDocument.uri).d;
	if (!d.enableStaticLinting || !d.enableLinting)
		return;

	int delay = document.length > 50 * 1024 ? 1000 : 200; // be slower after 50KiB
	clearTimeout(dscannerChangeTimeout);
	dscannerChangeTimeout = setTimeout({
		import served.linters.dscanner;

		lint(document);
		// Delay to avoid too many requests
	}, delay);
}

@protocolMethod("served/getDscannerConfig")
DScannerIniSection[] getDscannerConfig(DocumentLinkParams params)
{
	import served.linters.dscanner : getDscannerIniForDocument;

	auto instance = backend.getBestInstance!DscannerComponent(
			params.textDocument.uri.uriToFile);

	if (!instance)
		return null;

	string ini = "dscanner.ini";
	if (params.textDocument.uri.length)
		ini = getDscannerIniForDocument(params.textDocument.uri, instance);

	auto config = instance.get!DscannerComponent.getConfig(ini);

	DScannerIniSection sec;
	sec.description = __traits(getAttributes, typeof(config))[0].msg;
	sec.name = __traits(getAttributes, typeof(config))[0].name;

	DScannerIniFeature feature;
	foreach (i, ref val; config.tupleof)
	{
		static if (is(typeof(val) == string))
		{
			feature = DScannerIniFeature.init;
			feature.description = __traits(getAttributes, config.tupleof[i])[0].msg;
			feature.name = __traits(identifier, config.tupleof[i]);
			feature.enabled = val;
			sec.features ~= feature;
		}
	}

	return [sec];
}

@protocolNotification("textDocument/didSave")
void onDidSaveDocument(DidSaveTextDocumentParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto config = workspace(params.textDocument.uri).config;
	auto document = documents[params.textDocument.uri];
	auto fileName = params.textDocument.uri.uriToFile.baseName;

	if (document.getLanguageId == "d" || document.getLanguageId == "diet")
	{
		if (!config.d.enableLinting)
			return;
		joinAll({
			if (config.d.enableStaticLinting)
			{
				import served.linters.dscanner;

				lint(document);
				clearTimeout(dscannerChangeTimeout);
			}
		}, {
			if (config.d.enableDubLinting)
			{
				import served.linters.dub;

				lint(document);
			}
		});
	}
}

shared static this()
{
	import core.time : MonoTime;
	startupTime = MonoTime.currTime();
}

shared static this()
{
	backend = new LazyWorkspaceD();

	backend.messageHandler = new MessageHandler();
	backend.onBindFail = (WorkspaceD.Instance instance, ComponentFactory factory, Exception err) {
		if (!instance && err.msg.canFind("requires to be instanced"))
			return;

		if (factory.info.name == "dcd")
		{
			error("Failed to attach DCD component to ", instance ? instance.cwd : null, ": ", err.msg);
			if (instance && !dcdUpdating)
				instance.config.set("dcd", "errorlog", instance.config.get("dcd",
						"errorlog", "") ~ "\n" ~ err.msg);
			return;
		}

		tracef("bind fail:\n\tinstance %s\n\tfactory %s\n\tstacktrace:\n%s\n------",
				instance, factory.info.name, err);
		if (instance)
		{
			rpc.window.showErrorMessage(
					"Failed to load component " ~ factory.info.name ~ " for workspace "
					~ instance.cwd ~ "\n\nError: " ~ err.msg);
		}
	};
}

shared static ~this()
{
	if (backend)
		backend.shutdown();
}
