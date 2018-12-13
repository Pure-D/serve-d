module served.extension;

import core.exception;
import core.thread : Fiber, Thread;
import core.sync.mutex;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime.systime;
import std.datetime.stopwatch;
import fs = std.file;
import std.experimental.logger;
import std.functional;
import std.json;
import std.path;
import std.regex;
import io = std.stdio;
import std.string;
import rm.rf;

import served.ddoc;
import served.fibermanager;
import served.types;
import served.translate;
import served.filereader;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.com.importer;
import workspaced.coms;

import served.linters.dub : DubDiagnosticSource;
import served.linters.dscanner : DScannerDiagnosticSource;

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

__gshared bool dcdUpdating;
@protocolNotification("served/updateDCD")
void updateDCD()
{
	scope (exit)
		dcdUpdating = false;

	rpc.notifyMethod("coded/logInstall", "Installing DCD");
	string outputFolder = determineOutputFolder;
	if (fs.exists(outputFolder))
		rmdirRecurseForce(outputFolder);
	if (!fs.exists(outputFolder))
		fs.mkdirRecurse(outputFolder);
	string ext = "";
	version (Windows)
		ext = ".exe";
	string finalDestinationClient;
	string finalDestinationServer;

	bool success;

	enum bundledDCDVersion = "v0.9.13";

	bool compileFromSource = false;
	version (DCDFromSource)
		compileFromSource = true;
	else
	{
		if (!checkVersion(bundledDCDVersion, DCDComponent.latestKnownVersion))
			compileFromSource = true;
	}

	string[] triedPaths;

	if (compileFromSource)
	{
		string[] platformOptions;
		version (Windows)
			platformOptions = ["--arch=x86_mscoff"];
		success = compileDependency(outputFolder, "DCD", "https://github.com/Hackerpilot/DCD.git", [[firstConfig.git.path,
				"submodule", "update", "--init", "--recursive"], ["dub", "build",
				"--config=client"] ~ platformOptions, ["dub", "build",
				"--config=server"] ~ platformOptions]);
		finalDestinationClient = buildPath(outputFolder, "DCD", "dcd-client" ~ ext);
		if (!fs.exists(finalDestinationClient))
			finalDestinationClient = buildPath(outputFolder, "DCD", "bin", "dcd-client" ~ ext);
		finalDestinationServer = buildPath(outputFolder, "DCD", "dcd-server" ~ ext);
		if (!fs.exists(finalDestinationServer))
			finalDestinationServer = buildPath(outputFolder, "DCD", "bin", "dcd-server" ~ ext);

		triedPaths = ["DCD/dcd-client" ~ ext, "DCD/dcd-server" ~ ext,
			"DCD/bin/dcd-client" ~ ext, "DCD/bin/dcd-server" ~ ext];
	}
	else
	{
		string url;

		enum commonPrefix = "https://github.com/dlang-community/DCD/releases/download/"
			~ bundledDCDVersion ~ "/dcd-" ~ bundledDCDVersion;

		version (Win32)
			url = commonPrefix ~ "-windows-x86.zip";
		else version (Win64)
			url = commonPrefix ~ "-windows-x86_64.zip";
		else version (linux)
			url = commonPrefix ~ "-linux-x86_64.tar.gz";
		else version (OSX)
			url = commonPrefix ~ "-osx-x86_64.tar.gz";
		else
			static assert(false);

		import std.net.curl : download;
		import std.process : pipeProcess, Redirect, Config, wait;
		import std.zip : ZipArchive;

		try
		{
			rpc.notifyMethod("coded/logInstall", "Downloading from " ~ url ~ " to " ~ outputFolder);
			string destDir = buildPath(outputFolder, url.baseName);
			download(url, destDir);
			rpc.notifyMethod("coded/logInstall", "Extracting download...");
			if (url.endsWith(".tar.gz"))
			{
				rpc.notifyMethod("coded/logInstall", "> tar xvfz " ~ url.baseName);
				auto proc = pipeProcess(["tar", "xvfz", url.baseName],
						Redirect.stdout | Redirect.stderrToStdout, null, Config.none, outputFolder);
				foreach (line; proc.stdout.byLineCopy)
					rpc.notifyMethod("coded/logInstall", line);
				proc.pid.wait;
			}
			else if (url.endsWith(".zip"))
			{
				auto zip = new ZipArchive(fs.read(destDir));
				foreach (name, am; zip.directory)
				{
					if (name.isAbsolute)
						name = "." ~ name;
					zip.expand(am);
					fs.write(chainPath(outputFolder, name), am.expandedData);
				}
			}
			success = true;

			finalDestinationClient = buildPath(outputFolder, "dcd-client" ~ ext);
			finalDestinationServer = buildPath(outputFolder, "dcd-server" ~ ext);

			if (!fs.exists(finalDestinationClient))
				finalDestinationClient = buildPath(outputFolder, "bin", "dcd-client" ~ ext);
			if (!fs.exists(finalDestinationServer))
				finalDestinationServer = buildPath(outputFolder, "bin", "dcd-client" ~ ext);

			triedPaths = ["dcd-client" ~ ext, "dcd-server" ~ ext,
				"bin/dcd-client" ~ ext, "bin/dcd-server" ~ ext];
		}
		catch (Exception e)
		{
			rpc.notifyMethod("coded/logInstall", "Failed installing: " ~ e.toString);
			success = false;
		}
	}

	if (success && (!fs.exists(finalDestinationClient) || !fs.exists(finalDestinationServer)))
	{
		rpc.notifyMethod("coded/logInstall",
				"Successfully downloaded DCD, but could not find the executables.");
		rpc.notifyMethod("coded/logInstall",
				"Please open your user settings and insert the paths for dcd-client and dcd-server manually.");
		rpc.notifyMethod("coded/logInstall", "Download base location: " ~ outputFolder);
		rpc.notifyMethod("coded/logInstall", "");
		rpc.notifyMethod("coded/logInstall", format("Tried %(%s, %)", triedPaths));

		finalDestinationClient = "dcd-client";
		finalDestinationServer = "dcd-server";
	}

	if (success)
	{
		backend.globalConfiguration.set("dcd", "clientPath", finalDestinationClient);
		backend.globalConfiguration.set("dcd", "serverPath", finalDestinationServer);

		foreach (ref workspace; workspaces)
		{
			workspace.config.d.dcdClientPath = finalDestinationClient;
			workspace.config.d.dcdServerPath = finalDestinationServer;
		}
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdClientPath",
				JSONValue(finalDestinationClient), true));
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdServerPath",
				JSONValue(finalDestinationServer), true));
		rpc.notifyMethod("coded/logInstall", "Successfully installed DCD");
		foreach (ref workspace; workspaces)
		{
			auto instance = backend.getInstance(workspace.folder.uri.uriToFile);
			if (instance is null)
				rpc.notifyMethod("coded/logInstall",
						"Failed to find workspace to start DCD for " ~ workspace.folder.uri);
			else
			{
				instance.config.set("dcd", "clientPath", finalDestinationClient);
				instance.config.set("dcd", "serverPath", finalDestinationServer);

				startDCD(instance, workspace.folder.uri);
			}
		}
	}
}

bool compileDependency(string cwd, string name, string gitURI, string[][] commands)
{
	import std.process;

	int run(string[] cmd, string cwd)
	{
		import core.thread;

		rpc.notifyMethod("coded/logInstall", "> " ~ cmd.join(" "));
		auto stdin = pipe();
		auto stdout = pipe();
		auto pid = spawnProcess(cmd, stdin.readEnd, stdout.writeEnd,
				stdout.writeEnd, null, Config.none, cwd);
		stdin.writeEnd.close();
		size_t i;
		string[] lines;
		bool done;
		new Thread({
			scope (exit)
				done = true;
			foreach (line; stdout.readEnd.byLine)
				lines ~= line.idup;
		}).start();
		while (!pid.tryWait().terminated || !done || i < lines.length)
		{
			if (i < lines.length)
			{
				rpc.notifyMethod("coded/logInstall", lines[i++]);
			}
			Fiber.yield();
		}
		return pid.wait;
	}

	rpc.notifyMethod("coded/logInstall", "Installing into " ~ cwd);
	try
	{
		auto newCwd = buildPath(cwd, name);
		if (fs.exists(newCwd))
		{
			rpc.notifyMethod("coded/logInstall", "Deleting old installation from " ~ newCwd);
			try
			{
				rmdirRecurseForce(newCwd);
			}
			catch (Exception)
			{
				rpc.notifyMethod("coded/logInstall", "WARNING: Failed to delete " ~ newCwd);
			}
		}
		auto ret = run([firstConfig.git.path, "clone", "--recursive", "--depth=1", gitURI, name], cwd);
		if (ret != 0)
			throw new Exception("git ended with error code " ~ ret.to!string);
		foreach (command; commands)
			run(command, newCwd);
		return true;
	}
	catch (Exception e)
	{
		rpc.notifyMethod("coded/logInstall", "Failed to install " ~ name);
		rpc.notifyMethod("coded/logInstall", e.toString);
		return false;
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

CompletionItemKind convertFromDCDType(string type)
{
	switch (type)
	{
	case "c":
		return CompletionItemKind.class_;
	case "i":
		return CompletionItemKind.interface_;
	case "s":
	case "u":
		return CompletionItemKind.unit;
	case "a":
	case "A":
	case "v":
		return CompletionItemKind.variable;
	case "m":
	case "e":
		return CompletionItemKind.field;
	case "k":
		return CompletionItemKind.keyword;
	case "f":
		return CompletionItemKind.function_;
	case "g":
		return CompletionItemKind.enum_;
	case "P":
	case "M":
		return CompletionItemKind.module_;
	case "l":
		return CompletionItemKind.reference;
	case "t":
	case "T":
		return CompletionItemKind.property;
	default:
		return CompletionItemKind.text;
	}
}

SymbolKind convertFromDCDSearchType(string type)
{
	switch (type)
	{
	case "c":
		return SymbolKind.class_;
	case "i":
		return SymbolKind.interface_;
	case "s":
	case "u":
		return SymbolKind.package_;
	case "a":
	case "A":
	case "v":
		return SymbolKind.variable;
	case "m":
	case "e":
		return SymbolKind.field;
	case "f":
	case "l":
		return SymbolKind.function_;
	case "g":
		return SymbolKind.enum_;
	case "P":
	case "M":
		return SymbolKind.namespace;
	case "t":
	case "T":
		return SymbolKind.property;
	case "k":
	default:
		return cast(SymbolKind) 0;
	}
}

SymbolKind convertFromDscannerType(string type)
{
	switch (type)
	{
	case "g":
		return SymbolKind.enum_;
	case "e":
		return SymbolKind.field;
	case "v":
		return SymbolKind.variable;
	case "i":
		return SymbolKind.interface_;
	case "c":
		return SymbolKind.class_;
	case "s":
		return SymbolKind.class_;
	case "f":
		return SymbolKind.function_;
	case "u":
		return SymbolKind.class_;
	case "T":
		return SymbolKind.property;
	case "a":
		return SymbolKind.field;
	default:
		return cast(SymbolKind) 0;
	}
}

string substr(T)(string s, T start, T end)
{
	if (!s.length)
		return "";
	if (start < 0)
		start = 0;
	if (start >= s.length)
		start = s.length - 1;
	if (end > s.length)
		end = s.length;
	if (end < start)
		return s[start .. start];
	return s[start .. end];
}

string[] extractFunctionParameters(string sig, bool exact = false)
{
	if (!sig.length)
		return [];
	string[] params;
	ptrdiff_t i = sig.length - 1;

	if (sig[i] == ')' && !exact)
		i--;

	ptrdiff_t paramEnd = i + 1;

	void skipStr()
	{
		i--;
		if (sig[i + 1] == '\'')
			for (; i >= 0; i--)
				if (sig[i] == '\'')
					return;
		bool escapeNext = false;
		while (i >= 0)
		{
			if (sig[i] == '\\')
				escapeNext = false;
			if (escapeNext)
				break;
			if (sig[i] == '"')
				escapeNext = true;
			i--;
		}
	}

	void skip(char open, char close)
	{
		i--;
		int depth = 1;
		while (i >= 0 && depth > 0)
		{
			if (sig[i] == '"' || sig[i] == '\'')
				skipStr();
			else
			{
				if (sig[i] == close)
					depth++;
				else if (sig[i] == open)
					depth--;
				i--;
			}
		}
	}

	while (i >= 0)
	{
		switch (sig[i])
		{
		case ',':
			params ~= sig.substr(i + 1, paramEnd).strip;
			paramEnd = i;
			i--;
			break;
		case ';':
		case '(':
			auto param = sig.substr(i + 1, paramEnd).strip;
			if (param.length)
				params ~= param;
			reverse(params);
			return params;
		case ')':
			skip('(', ')');
			break;
		case '}':
			skip('{', '}');
			break;
		case ']':
			skip('[', ']');
			break;
		case '"':
		case '\'':
			skipStr();
			break;
		default:
			i--;
			break;
		}
	}
	reverse(params);
	return params;
}

unittest
{
	void assertEqual(A, B)(A a, B b)
	{
		import std.conv : to;

		assert(a == b, a.to!string ~ " is not equal to " ~ b.to!string);
	}

	assertEqual(extractFunctionParameters("void foo()"), cast(string[])[]);
	assertEqual(extractFunctionParameters(`auto bar(int foo, Button, my.Callback cb)`),
			["int foo", "Button", "my.Callback cb"]);
	assertEqual(extractFunctionParameters(`SomeType!(int, "int_") foo(T, Args...)(T a, T b, string[string] map, Other!"(" stuff1, SomeType!(double, ")double") myType, Other!"(" stuff, Other!")")`),
			["T a", "T b", "string[string] map", `Other!"(" stuff1`,
			`SomeType!(double, ")double") myType`, `Other!"(" stuff`, `Other!")"`]);
	assertEqual(extractFunctionParameters(`SomeType!(int,"int_")foo(T,Args...)(T a,T b,string[string] map,Other!"(" stuff1,SomeType!(double,")double")myType,Other!"(" stuff,Other!")")`),
			["T a", "T b", "string[string] map", `Other!"(" stuff1`,
			`SomeType!(double,")double")myType`, `Other!"(" stuff`, `Other!")"`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4`,
			true), [`4`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4, f(4)`,
			true), [`4`, `f(4)`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4, ["a"], JSONValue(["b": JSONValue("c")]), recursive(func, call!s()), "texts )\"(too"`,
			true), [`4`, `["a"]`, `JSONValue(["b": JSONValue("c")])`,
			`recursive(func, call!s())`, `"texts )\"(too"`]);
}

// === Protocol Methods starting here ===

@protocolMethod("textDocument/completion")
CompletionList provideComplete(TextDocumentPositionParams params)
{
	import painlessjson : fromJSON;

	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	Document document = documents[params.textDocument.uri];
	if (document.uri.toLower.endsWith("dscanner.ini"))
	{
		auto possibleFields = backend.get!DscannerComponent.listAllIniFields;
		auto line = document.lineAt(params.position).strip;
		auto defaultList = CompletionList(false, possibleFields.map!(a => CompletionItem(a.name,
				CompletionItemKind.field.opt, Optional!string.init,
				MarkupContent(a.documentation).opt, Optional!bool.init, Optional!bool.init,
				Optional!string.init, Optional!string.init, (a.name ~ '=').opt)).array);
		if (!line.length)
			return defaultList;
		//dfmt off
		if (line[0] == '[')
			return CompletionList(false, [
				CompletionItem("analysis.config.StaticAnalysisConfig", CompletionItemKind.keyword.opt),
				CompletionItem("analysis.config.ModuleFilters", CompletionItemKind.keyword.opt, Optional!string.init,
					MarkupContent("In this optional section a comma-separated list of inclusion and exclusion"
					~ " selectors can be specified for every check on which selective filtering"
					~ " should be applied. These given selectors match on the module name and"
					~ " partial matches (std. or .foo.) are possible. Moreover, every selectors"
					~ " must begin with either + (inclusion) or - (exclusion). Exclusion selectors"
					~ " take precedence over all inclusion operators.").opt)
			]);
		//dfmt on
		auto eqIndex = line.indexOf('=');
		auto quotIndex = line.lastIndexOf('"');
		if (quotIndex != -1 && params.position.character >= quotIndex)
			return CompletionList.init;
		if (params.position.character < eqIndex)
			return defaultList;
		else//dfmt off
			return CompletionList(false, [
				CompletionItem(`"disabled"`, CompletionItemKind.value.opt, "Check is disabled".opt),
				CompletionItem(`"enabled"`, CompletionItemKind.value.opt, "Check is enabled".opt),
				CompletionItem(`"skip-unittest"`, CompletionItemKind.value.opt,
					"Check is enabled but not operated in the unittests".opt)
			]);
		//dfmt on
	}
	else
	{
		if (document.languageId == "d")
			return provideDSourceComplete(params, workspaceRoot, document);
		else if (document.languageId == "diet")
			return provideDietSourceComplete(params, workspaceRoot, document);
		else
			return CompletionList.init;
	}
}

CompletionList provideDietSourceComplete(TextDocumentPositionParams params,
		string workspaceRoot, ref Document document)
{
	import served.diet;
	import dc = dietc.complete;

	auto completion = updateDietFile(document.uri.uriToFile, workspaceRoot, document.text);

	size_t offset = document.positionToBytes(params.position);
	auto raw = completion.completeAt(offset);
	CompletionItem[] ret;

	if (raw is dc.Completion.completeD)
	{
		string code;
		dc.extractD(completion, offset, code, offset);
		if (offset <= code.length && backend.has!DCDComponent(workspaceRoot))
		{
			info("DCD Completing Diet for ", code, " at ", offset);
			auto dcd = backend.get!DCDComponent(workspaceRoot).listCompletion(code,
					cast(int) offset).getYield;
			if (dcd.type == DCDCompletions.Type.identifiers)
				ret = dcd.identifiers.convertDCDIdentifiers(workspace(params.textDocument.uri)
						.config.d.argumentSnippets);
		}
	}
	else
		ret = raw.map!((a) {
			CompletionItem ret;
			ret.label = a.text;
			ret.kind = a.type.mapToCompletionItemKind.opt;
			if (a.definition.length)
				ret.detail = a.definition.opt;
			if (a.documentation.length)
				ret.documentation = MarkupContent(a.documentation).opt;
			if (a.preselected)
				ret.preselect = true.opt;
			return ret;
		}).array;

	return CompletionList(false, ret);
}

CompletionList provideDSourceComplete(TextDocumentPositionParams params,
		string workspaceRoot, ref Document document)
{
	string line = document.lineAt(params.position);
	string prefix = line[0 .. min($, params.position.character)];
	CompletionItem[] completion;
	if (prefix.strip == "///" || prefix.strip == "*")
	{
		foreach (compl; import("ddocs.txt").lineSplitter)
		{
			auto item = CompletionItem(compl, CompletionItemKind.snippet.opt);
			item.insertText = compl ~ ": ";
			completion ~= item;
		}
		return CompletionList(false, completion);
	}
	auto byteOff = cast(int) document.positionToBytes(params.position);
	DCDCompletions result = DCDCompletions.empty;
	joinAll({
		if (backend.has!DCDComponent(workspaceRoot))
			result = backend.get!DCDComponent(workspaceRoot)
				.listCompletion(document.text, byteOff).getYield;
	}, {
		if (!line.strip.length)
		{
			auto defs = backend.get!DscannerComponent(workspaceRoot)
				.listDefinitions(uriToFile(params.textDocument.uri), document.text).getYield;
			ptrdiff_t di = -1;
			FuncFinder: foreach (i, def; defs)
			{
				for (int n = 1; n < 5; n++)
					if (def.line == params.position.line + n)
					{
						di = i;
						break FuncFinder;
					}
			}
			if (di == -1)
				return;
			auto def = defs[di];
			auto sig = "signature" in def.attributes;
			if (!sig)
			{
				CompletionItem doc = CompletionItem("///");
				doc.kind = CompletionItemKind.snippet;
				doc.insertTextFormat = InsertTextFormat.snippet;
				auto eol = document.eolAt(params.position.line).toString;
				doc.insertText = "/// ";
				CompletionItem doc2 = doc;
				doc2.label = "/**";
				doc2.insertText = "/** " ~ eol ~ " * $0" ~ eol ~ " */";
				completion ~= doc;
				completion ~= doc2;
				return;
			}
			auto funcArgs = extractFunctionParameters(*sig);
			string[] docs;
			if (def.name.matchFirst(ctRegex!`^[Gg]et([^a-z]|$)`))
				docs ~= "Gets $0";
			else if (def.name.matchFirst(ctRegex!`^[Ss]et([^a-z]|$)`))
				docs ~= "Sets $0";
			else if (def.name.matchFirst(ctRegex!`^[Ii]s([^a-z]|$)`))
				docs ~= "Checks if $0";
			else
				docs ~= "$0";
			int argNo = 1;
			foreach (arg; funcArgs)
			{
				auto space = arg.lastIndexOf(' ');
				if (space == -1)
					continue;
				string identifier = arg[space + 1 .. $];
				if (!identifier.matchFirst(ctRegex!`[a-zA-Z_][a-zA-Z0-9_]*`))
					continue;
				if (argNo == 1)
					docs ~= "Params:";
				docs ~= "  " ~ identifier ~ " = $" ~ argNo.to!string;
				argNo++;
			}
			auto retAttr = "return" in def.attributes;
			if (retAttr && *retAttr != "void")
			{
				docs ~= "Returns: $" ~ argNo.to!string;
				argNo++;
			}
			auto depr = "deprecation" in def.attributes;
			if (depr)
			{
				docs ~= "Deprecated: $" ~ argNo.to!string ~ *depr;
				argNo++;
			}
			CompletionItem doc = CompletionItem("///");
			doc.kind = CompletionItemKind.snippet;
			doc.insertTextFormat = InsertTextFormat.snippet;
			auto eol = document.eolAt(params.position.line).toString;
			doc.insertText = docs.map!(a => "/// " ~ a).join(eol);
			CompletionItem doc2 = doc;
			doc2.label = "/**";
			doc2.insertText = "/** " ~ eol ~ docs.map!(a => " * " ~ a ~ eol).join() ~ " */";
			completion ~= doc;
			completion ~= doc2;
		}
	});
	switch (result.type)
	{
	case DCDCompletions.Type.identifiers:
		completion = convertDCDIdentifiers(result.identifiers,
				workspace(params.textDocument.uri).config.d.argumentSnippets);
		goto case;
	case DCDCompletions.Type.calltips:
		return CompletionList(false, completion);
	default:
		throw new Exception("Unexpected result from DCD:\n\t" ~ result.raw.join("\n\t"));
	}
}

auto convertDCDIdentifiers(DCDIdentifier[] identifiers, lazy bool argumentSnippets)
{
	CompletionItem[] completion;
	foreach (identifier; identifiers)
	{
		CompletionItem item;
		item.label = identifier.identifier;
		item.kind = identifier.type.convertFromDCDType;
		if (identifier.documentation.length)
			item.documentation = MarkupContent(identifier.documentation.ddocToMarked);
		if (identifier.definition.length)
		{
			item.detail = identifier.definition;
			item.sortText = identifier.definition;
			// TODO: only add arguments when this is a function call, eg not on template arguments
			if (identifier.type == "f" && argumentSnippets)
			{
				item.insertTextFormat = InsertTextFormat.snippet;
				string args;
				auto parts = identifier.definition.extractFunctionParameters;
				if (parts.length)
				{
					bool isOptional;
					string[] optionals;
					int numRequired;
					foreach (i, part; parts)
					{
						if (!isOptional)
							isOptional = part.canFind('=');
						if (isOptional)
							optionals ~= part;
						else
						{
							if (args.length)
								args ~= ", ";
							args ~= "${" ~ (i + 1).to!string ~ ":" ~ part ~ "}";
							numRequired++;
						}
					}
					foreach (i, part; optionals)
					{
						if (args.length)
							part = ", " ~ part;
						// Go through optionals in reverse
						args ~= "${" ~ (numRequired + optionals.length - i).to!string ~ ":" ~ part ~ "}";
					}
					item.insertText = identifier.identifier ~ "(${0:" ~ args ~ "})";
				}
			}
		}
		completion ~= item;
	}
	return completion;
}

SignatureHelp convertDCDCalltips(string[] calltips,
		DCDCompletions.Symbol[] symbols, string textTilCursor)
{
	SignatureInformation[] signatures;
	int[] paramsCounts;
	SignatureHelp help;
	foreach (i, calltip; calltips)
	{
		auto sig = SignatureInformation(calltip);
		immutable DCDCompletions.Symbol symbol = symbols[i];
		if (symbol.documentation.length)
			sig.documentation = MarkupContent(symbol.documentation.ddocToMarked);
		auto funcParams = calltip.extractFunctionParameters;

		paramsCounts ~= cast(int) funcParams.length - 1;
		foreach (param; funcParams)
			sig.parameters ~= ParameterInformation(param);

		help.signatures ~= sig;
	}
	auto extractedParams = textTilCursor.extractFunctionParameters(true);
	help.activeParameter = max(0, cast(int) extractedParams.length - 1);
	size_t[] possibleFunctions;
	foreach (i, count; paramsCounts)
		if (count >= cast(int) extractedParams.length - 1)
			possibleFunctions ~= i;
	help.activeSignature = possibleFunctions.length ? cast(int) possibleFunctions[0] : 0;
	return help;
}

@protocolMethod("textDocument/signatureHelp")
SignatureHelp provideSignatureHelp(TextDocumentPositionParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	if (document.languageId == "d")
		return provideDSignatureHelp(params, workspaceRoot, document);
	else if (document.languageId == "diet")
		return provideDietSignatureHelp(params, workspaceRoot, document);
	else
		return SignatureHelp.init;
}

SignatureHelp provideDSignatureHelp(TextDocumentPositionParams params,
		string workspaceRoot, ref Document document)
{
	if (!backend.has!DCDComponent(workspaceRoot))
		return SignatureHelp.init;

	auto pos = cast(int) document.positionToBytes(params.position);
	DCDCompletions result = backend.get!DCDComponent(workspaceRoot)
		.listCompletion(document.text, pos).getYield;
	switch (result.type)
	{
	case DCDCompletions.Type.calltips:
		return convertDCDCalltips(result.calltips,
				result.symbols, document.text[0 .. pos]);
	case DCDCompletions.Type.identifiers:
		return SignatureHelp.init;
	default:
		throw new Exception("Unexpected result from DCD");
	}
}

SignatureHelp provideDietSignatureHelp(TextDocumentPositionParams params,
		string workspaceRoot, ref Document document)
{
	import served.diet;
	import dc = dietc.complete;

	auto completion = updateDietFile(document.uri.uriToFile, workspaceRoot, document.text);

	size_t offset = document.positionToBytes(params.position);
	auto raw = completion.completeAt(offset);
	CompletionItem[] ret;

	if (raw is dc.Completion.completeD)
	{
		string code;
		dc.extractD(completion, offset, code, offset);
		if (offset <= code.length && backend.has!DCDComponent(workspaceRoot))
		{
			auto dcd = backend.get!DCDComponent(workspaceRoot).listCompletion(code,
					cast(int) offset).getYield;
			if (dcd.type == DCDCompletions.Type.calltips)
				return convertDCDCalltips(dcd.calltips, dcd.symbols, code[0 .. offset]);
		}
	}
	return SignatureHelp.init;
}

@protocolMethod("workspace/symbol")
SymbolInformation[] provideWorkspaceSymbols(WorkspaceSymbolParams params)
{
	SymbolInformation[] infos;
	foreach (workspace; workspaces)
	{
		string workspaceRoot = workspace.folder.uri.uriToFile;
		foreach (file; fs.dirEntries(workspaceRoot, fs.SpanMode.depth, false))
		{
			if (!file.isFile || file.extension != ".d")
				continue;
			auto defs = provideDocumentSymbolsOld(
					DocumentSymbolParams(TextDocumentIdentifier(file.uriFromFile)));
			foreach (def; defs)
				if (def.name.toLower.startsWith(params.query.toLower))
					infos ~= def.downcast;
		}
		if (backend.has!DCDComponent(workspace.folder.uri.uriToFile))
		{
			auto exact = backend.get!DCDComponent(workspace.folder.uri.uriToFile)
				.searchSymbol(params.query).getYield;
			foreach (symbol; exact)
			{
				if (!symbol.file.isAbsolute)
					continue;
				string uri = symbol.file.uriFromFile;
				if (infos.canFind!(a => a.location.uri == uri))
					continue;
				SymbolInformation info;
				info.name = params.query;
				info.location.uri = uri;
				auto doc = documents.tryGet(uri);
				if (doc != Document.init)
					info.location.range = TextRange(doc.bytesToPosition(symbol.position));
				info.kind = symbol.type.convertFromDCDSearchType;
				infos ~= info;
			}
		}
	}
	return infos;
}

@protocolMethod("textDocument/documentSymbol")
JSONValue provideDocumentSymbols(DocumentSymbolParams params)
{
	import painlessjson : toJSON;

	if (capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport)
		return provideDocumentSymbolsHierarchical(params).toJSON;
	else
		return provideDocumentSymbolsOld(params).map!"a.downcast".array.toJSON;
}

PerDocumentCache!(SymbolInformationEx[]) documentSymbolsCacheOld;
SymbolInformationEx[] provideDocumentSymbolsOld(DocumentSymbolParams params)
{
	auto cached = documentSymbolsCacheOld.cached(documents, params.textDocument.uri);
	if (cached.length)
		return cached;
	auto document = documents.tryGet(params.textDocument.uri);
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto result = backend.get!DscannerComponent(workspaceRoot)
		.listDefinitions(uriToFile(params.textDocument.uri), document.text).getYield;
	SymbolInformationEx[] ret;
	foreach (def; result)
	{
		SymbolInformationEx info;
		info.name = def.name;
		info.location.uri = params.textDocument.uri;
		info.location.range = TextRange(document.bytesToPosition(def.range[0]),
				document.bytesToPosition(def.range[1]));
		info.kind = convertFromDscannerType(def.type);
		if (def.type == "f" && def.name == "this")
			info.kind = SymbolKind.constructor;
		string* ptr;
		auto attribs = def.attributes;
		if ((ptr = "struct" in attribs) !is null || (ptr = "class" in attribs) !is null
				|| (ptr = "enum" in attribs) !is null || (ptr = "union" in attribs) !is null)
			info.containerName = *ptr;
		if ("deprecation" in attribs)
			info.deprecated_ = true;
		ret ~= info;
	}
	documentSymbolsCacheOld.store(document, ret);
	return ret;
}

PerDocumentCache!(DocumentSymbol[]) documentSymbolsCacheHierarchical;
DocumentSymbol[] provideDocumentSymbolsHierarchical(DocumentSymbolParams params)
{
	auto cached = documentSymbolsCacheHierarchical.cached(documents, params.textDocument.uri);
	if (cached.length)
		return cached;
	DocumentSymbol[] all;
	auto symbols = provideDocumentSymbolsOld(params);
	foreach (symbol; symbols)
	{
		DocumentSymbol sym;
		static foreach (member; __traits(allMembers, SymbolInformationEx))
			static if (__traits(hasMember, DocumentSymbol, member))
				__traits(getMember, sym, member) = __traits(getMember, symbol, member);
		sym.parent = symbol.containerName;
		sym.range = sym.selectionRange = symbol.location.range;
		sym.selectionRange.end.line = sym.selectionRange.start.line;
		if (sym.selectionRange.end.character < sym.selectionRange.start.character)
			sym.selectionRange.end.character = sym.selectionRange.start.character;
		all ~= sym;
	}

	foreach (ref sym; all)
	{
		if (sym.parent.length)
		{
			foreach (ref other; all)
			{
				if (other.name == sym.parent)
				{
					other.children ~= sym;
					break;
				}
			}
		}
	}

	DocumentSymbol[] ret = all.filter!(a => a.parent.length == 0).array;
	documentSymbolsCacheHierarchical.store(documents.tryGet(params.textDocument.uri), ret);
	return ret;
}

@protocolMethod("textDocument/definition")
ArrayOrSingle!Location provideDefinition(TextDocumentPositionParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	if (!backend.has!DCDComponent(workspaceRoot))
		return ArrayOrSingle!Location.init;

	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return ArrayOrSingle!Location.init;

	auto result = backend.get!DCDComponent(workspaceRoot).findDeclaration(document.text,
			cast(int) document.positionToBytes(params.position)).getYield;
	if (result == DCDDeclaration.init)
		return ArrayOrSingle!Location.init;

	auto uri = document.uri;
	if (result.file != "stdin")
	{
		if (isAbsolute(result.file))
			uri = uriFromFile(result.file);
		else
			uri = null;
	}
	size_t byteOffset = cast(size_t) result.position;
	Position pos;
	auto found = documents.tryGet(uri);
	if (found.uri)
		pos = found.bytesToPosition(byteOffset);
	else
	{
		string abs = result.file;
		if (!abs.isAbsolute)
			abs = buildPath(workspaceRoot, abs);
		pos = Position.init;
		size_t totalLen;
		foreach (line; io.File(abs).byLine(io.KeepTerminator.yes))
		{
			totalLen += line.length;
			if (totalLen >= byteOffset)
				break;
			else
				pos.line++;
		}
	}
	return ArrayOrSingle!Location(Location(uri, TextRange(pos, pos)));
}

@protocolMethod("textDocument/formatting")
TextEdit[] provideFormatting(DocumentFormattingParams params)
{
	auto config = workspace(params.textDocument.uri).config;
	if (!config.d.enableFormatting)
		return [];
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	string[] args;
	if (config.d.overrideDfmtEditorconfig)
	{
		int maxLineLength = 120;
		int softMaxLineLength = 80;
		if (config.editor.rulers.length == 1)
		{
			maxLineLength = config.editor.rulers[0];
			softMaxLineLength = maxLineLength - 40;
		}
		else if (config.editor.rulers.length >= 2)
		{
			maxLineLength = config.editor.rulers[$ - 1];
			softMaxLineLength = config.editor.rulers[$ - 2];
		}
		//dfmt off
			args = [
				"--align_switch_statements", config.dfmt.alignSwitchStatements.to!string,
				"--brace_style", config.dfmt.braceStyle,
				"--end_of_line", document.eolAt(0).to!string,
				"--indent_size", params.options.tabSize.to!string,
				"--indent_style", params.options.insertSpaces ? "space" : "tab",
				"--max_line_length", maxLineLength.to!string,
				"--soft_max_line_length", softMaxLineLength.to!string,
				"--outdent_attributes", config.dfmt.outdentAttributes.to!string,
				"--space_after_cast", config.dfmt.spaceAfterCast.to!string,
				"--split_operator_at_line_end", config.dfmt.splitOperatorAtLineEnd.to!string,
				"--tab_width", params.options.tabSize.to!string,
				"--selective_import_space", config.dfmt.selectiveImportSpace.to!string,
				"--compact_labeled_statements", config.dfmt.compactLabeledStatements.to!string,
				"--template_constraint_style", config.dfmt.templateConstraintStyle
			];
			//dfmt on
	}
	auto result = backend.get!DfmtComponent.format(document.text, args).getYield;
	return [TextEdit(TextRange(Position(0, 0),
			document.offsetToPosition(document.text.length)), result)];
}

@protocolMethod("textDocument/hover")
Hover provideHover(TextDocumentPositionParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);

	if (!backend.has!DCDComponent(workspaceRoot))
		return Hover.init;

	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return Hover.init;

	auto docs = backend.get!DCDComponent(workspaceRoot).getDocumentation(document.text,
			cast(int) document.positionToBytes(params.position)).getYield;
	Hover ret;
	ret.contents = docs.ddocToMarked;
	return ret;
}

private auto importRegex = regex(`import\s+(?:[a-zA-Z_]+\s*=\s*)?([a-zA-Z_]\w*(?:\.\w*[a-zA-Z_]\w*)*)?(\s*\:\s*(?:[a-zA-Z_,\s=]*(?://.*?[\r\n]|/\*.*?\*/|/\+.*?\+/)?)+)?;?`);
private static immutable regexQuoteChars = "['\"`]?";
private auto undefinedIdentifier = regex(`^undefined identifier ` ~ regexQuoteChars ~ `(\w+)`
		~ regexQuoteChars ~ `(?:, did you mean .*? ` ~ regexQuoteChars ~ `(\w+)`
		~ regexQuoteChars ~ `\?)?$`);
private auto undefinedTemplate = regex(
		`template ` ~ regexQuoteChars ~ `(\w+)` ~ regexQuoteChars ~ ` is not defined`);
private auto noProperty = regex(`^no property ` ~ regexQuoteChars ~ `(\w+)`
		~ regexQuoteChars ~ `(?: for type ` ~ regexQuoteChars ~ `.*?` ~ regexQuoteChars ~ `)?$`);
private auto moduleRegex = regex(
		`(?<!//.*)\bmodule\s+([a-zA-Z_]\w*\s*(?:\s*\.\s*[a-zA-Z_]\w*)*)\s*;`);
private auto whitespace = regex(`\s*`);

@protocolMethod("textDocument/codeAction")
Command[] provideCodeActions(CodeActionParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	Command[] ret;
	if (backend.has!DCDExtComponent(workspaceRoot)) // check if extends
	{
		auto startIndex = document.positionToBytes(params.range.start);
		ptrdiff_t idx = min(cast(ptrdiff_t) startIndex, cast(ptrdiff_t) document.text.length - 1);
		while (idx > 0)
		{
			if (document.text[idx] == ':')
			{
				// probably extends
				if (backend.get!DCDExtComponent(workspaceRoot)
						.implement(document.text, cast(int) startIndex).getYield.strip.length > 0)
					ret ~= Command("Implement base classes/interfaces", "code-d.implementMethods",
							[JSONValue(document.positionToOffset(params.range.start))]);
				break;
			}
			if (document.text[idx] == ';' || document.text[idx] == '{' || document.text[idx] == '}')
				break;
			idx--;
		}
	}
	foreach (diagnostic; params.context.diagnostics)
	{
		if (diagnostic.source == DubDiagnosticSource)
		{
			auto match = diagnostic.message.matchFirst(importRegex);
			if (diagnostic.message.canFind("import ") && match)
			{
				ret ~= Command("Import " ~ match[1], "code-d.addImport",
						[JSONValue(match[1]), JSONValue(document.positionToOffset(params.range[0]))]);
			}
			if (cast(bool)(match = diagnostic.message.matchFirst(undefinedIdentifier))
					|| cast(bool)(match = diagnostic.message.matchFirst(undefinedTemplate))
					|| cast(bool)(match = diagnostic.message.matchFirst(noProperty)))
			{
				string[] files;
				string[] modules;
				int lineNo;
				joinAll({
					files ~= backend.get!DscannerComponent(workspaceRoot)
						.findSymbol(match[1]).getYield.map!"a.file".array;
				}, {
					if (backend.has!DCDComponent(workspaceRoot))
						files ~= backend.get!DCDComponent(workspaceRoot).searchSymbol(match[1]).getYield.map!"a.file".array;
				});
				info("Files: ", files);
				foreach (file; files.sort().uniq)
				{
					if (!isAbsolute(file))
						file = buildNormalizedPath(workspaceRoot, file);
					if (!fs.exists(file))
						continue;
					lineNo = 0;
					foreach (line; io.File(file).byLine)
					{
						if (++lineNo >= 100)
							break;
						auto match2 = line.matchFirst(moduleRegex);
						if (match2)
						{
							modules ~= match2[1].replaceAll(whitespace, "").idup;
							break;
						}
					}
				}
				foreach (mod; modules.sort().uniq)
					ret ~= Command("Import " ~ mod, "code-d.addImport", [JSONValue(mod),
							JSONValue(document.positionToOffset(params.range[0]))]);
			}
		}
		else if (diagnostic.source == DScannerDiagnosticSource)
		{
			import dscanner.analysis.imports_sortedness : ImportSortednessCheck;

			string key = diagnostic.code.type == JSON_TYPE.STRING ? diagnostic.code.str : null;

			info("Diagnostic: ", diagnostic);

			if (key == ImportSortednessCheck.KEY)
			{
				ret ~= Command("Sort imports", "code-d.sortImports",
						[JSONValue(document.positionToOffset(params.range[0]))]);
			}

			if (key.length)
			{
				if (key.startsWith("dscanner."))
					key = key["dscanner.".length .. $];
				ret ~= Command("Ignore " ~ key ~ " warnings", "code-d.ignoreDscannerKey", [diagnostic.code]);
				ret ~= Command("Ignore " ~ key ~ " warnings (this line)",
						"code-d.ignoreDscannerKey", [diagnostic.code, JSONValue("line")]);
			}
		}
	}
	return ret;
}

@protocolMethod("textDocument/codeLens")
CodeLens[] provideCodeLens(CodeLensParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	CodeLens[] ret;
	if (workspace(params.textDocument.uri).config.d.enableDMDImportTiming)
		foreach (match; document.text.matchAll(importRegex))
		{
			size_t index = match.pre.length;
			auto pos = document.bytesToPosition(index);
			ret ~= CodeLens(TextRange(pos), Optional!Command.init, JSONValue(["type"
					: JSONValue("importcompilecheck"), "code" : JSONValue(match.hit),
					"module" : JSONValue(match[1]), "workspace" : JSONValue(workspaceRoot)]));
		}
	return ret;
}

@protocolMethod("codeLens/resolve")
CodeLens resolveCodeLens(CodeLens lens)
{
	if (lens.data.type != JSON_TYPE.OBJECT)
		throw new Exception("Invalid Lens Object");
	auto type = "type" in lens.data;
	if (!type)
		throw new Exception("No type in Lens Object");
	switch (type.str)
	{
	case "importcompilecheck":
		try
		{
			auto code = "code" in lens.data;
			if (!code || code.type != JSON_TYPE.STRING || !code.str.length)
				throw new Exception("No valid code provided");
			auto module_ = "module" in lens.data;
			if (!module_ || module_.type != JSON_TYPE.STRING || !module_.str.length)
				throw new Exception("No valid module provided");
			auto workspace = "workspace" in lens.data;
			if (!workspace || workspace.type != JSON_TYPE.STRING || !workspace.str.length)
				throw new Exception("No valid workspace provided");
			int decMs = getImportCompilationTime(code.str, module_.str, workspace.str);
			lens.command = Command((decMs < 10 ? "no noticable effect"
					: "~" ~ decMs.to!string ~ "ms") ~ " for importing this");
			return lens;
		}
		catch (Exception)
		{
			lens.command = Command.init;
			return lens;
		}
	default:
		throw new Exception("Unknown lens type");
	}
}

bool importCompilationTimeRunning;
int getImportCompilationTime(string code, string module_, string workspaceRoot)
{
	import std.math : round;

	static struct CompileCache
	{
		SysTime at;
		string code;
		int ret;
	}

	static CompileCache[] cache;

	auto now = Clock.currTime;

	foreach_reverse (i, exist; cache)
	{
		if (exist.code != code)
			continue;
		if (now - exist.at < (exist.ret >= 500 ? 20.minutes : exist.ret >= 30 ? 5.minutes
				: 2.minutes) || module_.startsWith("std."))
			return exist.ret;
		else
		{
			cache[i] = cache[$ - 1];
			cache.length--;
		}
	}

	while (importCompilationTimeRunning)
		Fiber.yield();
	importCompilationTimeRunning = true;
	scope (exit)
		importCompilationTimeRunning = false;
	// run blocking so we don't compute multiple in parallel
	auto ret = backend.get!DMDComponent(workspaceRoot).measureSync(code, null, 20, 500);
	if (!ret.success)
		throw new Exception("Compilation failed");
	auto msecs = cast(int) round(ret.duration.total!"msecs" / 5.0) * 5;
	cache ~= CompileCache(now, code, msecs);
	StopWatch sw;
	sw.start();
	while (sw.peek < 100.msecs) // pass through requests for 100ms
		Fiber.yield();
	return msecs;
}

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

@protocolMethod("served/sortImports")
TextEdit[] sortImports(SortImportsParams params)
{
	auto document = documents[params.textDocument.uri];
	TextEdit[] ret;
	auto sorted = backend.get!ImporterComponent.sortImports(document.text,
			cast(int) document.offsetToBytes(params.location));
	if (sorted == ImportBlock.init)
		return ret;
	auto start = document.bytesToPosition(sorted.start);
	auto end = document.bytesToPosition(sorted.end);
	string code = sorted.imports.to!(string[]).join(document.eolAt(0).toString);
	return [TextEdit(TextRange(start, end), code)];
}

@protocolMethod("served/implementMethods")
TextEdit[] implementMethods(ImplementMethodsParams params)
{
	import std.ascii : isWhite;

	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	TextEdit[] ret;
	auto location = document.offsetToBytes(params.location);
	auto code = backend.get!DCDExtComponent(workspaceRoot)
		.implement(document.text, cast(int) location).getYield.strip;
	if (!code.length)
		return ret;
	auto brace = document.text.indexOf('{', location);
	auto fallback = brace;
	if (brace == -1)
		brace = document.text.length;
	else
	{
		fallback = document.text.indexOf('\n', location);
		brace = document.text.indexOfAny("}\n", brace);
		if (brace == -1)
			brace = document.text.length;
	}
	code = "\n\t" ~ code.replace("\n", document.eolAt(0).toString ~ "\t") ~ "\n";
	bool inIdentifier = true;
	int depth = 0;
	foreach (i; location .. brace)
	{
		if (document.text[i].isWhite)
			inIdentifier = false;
		else if (document.text[i] == '{')
			break;
		else if (document.text[i] == ',' || document.text[i] == '!')
			inIdentifier = true;
		else if (document.text[i] == '(')
			depth++;
		else
		{
			if (depth > 0)
			{
				inIdentifier = true;
				if (document.text[i] == ')')
					depth--;
			}
			else if (!inIdentifier)
			{
				if (fallback != -1)
					brace = fallback;
				code = "\n{" ~ code ~ "}";
				break;
			}
		}
	}
	auto pos = document.bytesToPosition(brace);
	return [TextEdit(TextRange(pos, pos), code)];
}

@protocolMethod("served/restartServer")
bool restartServer()
{
	Future!void[] fut;
	foreach (instance; backend.instances)
		if (instance.has!DCDComponent)
			fut ~= instance.get!DCDComponent.restartServer();
	joinAll(fut);
	return true;
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
			t.exec = [workspace.config.d.dubPath, "build",
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
			t.exec = [workspace.config.d.dubPath, "run", "--compiler=" ~ dub.compiler,
				"-a=" ~ dub.archType, "-b=" ~ dub.buildType, "-c=" ~ dub.configuration];
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
			t.exec = [workspace.config.d.dubPath, "build", "--force",
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
			t.exec = [workspace.config.d.dubPath, "test", "--compiler=" ~ dub.compiler,
				"-a=" ~ dub.archType, "-b=" ~ dub.buildType, "-c=" ~ dub.configuration];
			t.scope_ = workspace.folder.uri;
			t.name = "Test " ~ dub.name;
			ret ~= t;
		}
	}
	return ret;
}

@protocolMethod("served/searchFile")
string[] searchFile(string query)
{
	if (!query.length)
		return null;

	if (query.isAbsolute)
	{
		if (fs.exists(query))
			return [query];
		else
			return null;
	}

	string[] ret;
	string[] importFiles, importPaths;
	importPaths = selectedWorkspace.config.stdlibPath();

	foreach (instance; backend.instances)
	{
		importFiles ~= instance.importFiles;
		importPaths ~= instance.importPaths;
	}

	importFiles.sort!"a<b";
	importPaths.sort!"a<b";

	foreach (file; importFiles.uniq)
	{
		if (fs.exists(file) && fs.isFile(file))
			if (file.endsWith(query))
			{
				auto rest = file[0 .. $ - query.length];
				if (!rest.length || rest.endsWith("/", "\\"))
					ret ~= file;
			}
	}
	foreach (dir; importPaths.uniq)
	{
		if (fs.exists(dir) && fs.isDir(dir))
			foreach (filename; fs.dirEntries(dir, fs.SpanMode.breadth))
				if (filename.isFile)
				{
					auto file = buildPath(dir, filename);
					if (file.endsWith(query))
					{
						auto rest = file[0 .. $ - query.length];
						if (!rest.length || rest.endsWith("/", "\\"))
							ret ~= file;
					}
				}
	}

	return ret;
}

private string[] cachedModuleFiles;
private string[string] modFileCache;
@protocolMethod("served/findFilesByModule")
string[] findFilesByModule(string module_)
{
	if (!module_.length)
		return null;

	if (auto cache = module_ in modFileCache)
		return [*cache];

	ubyte[] buffer = new ubyte[8 * 1024];
	scope (exit)
		buffer.destroy();

	string[] ret;
	string[] importFiles, importPaths;
	importPaths = selectedWorkspace.config.stdlibPath();

	foreach (instance; backend.instances)
	{
		importFiles ~= instance.importFiles;
		importPaths ~= instance.importPaths;
	}

	importFiles.sort!"a<b";
	importPaths.sort!"a<b";

	foreach (file; importFiles.uniq)
	{
		if (cachedModuleFiles.binarySearch(file) >= 0)
			continue;
		if (fs.exists(file) && fs.isFile(file))
		{
			auto fileMod = backend.get!ModulemanComponent.moduleName(
					cast(string) file.readCodeWithBuffer(buffer));
			if (fileMod.startsWith("std"))
			{
				modFileCache[fileMod] = file;
				cachedModuleFiles.insertSorted(file);
			}
			if (fileMod == module_)
				ret ~= file;
		}
	}
	foreach (dir; importPaths.uniq)
	{
		if (fs.exists(dir) && fs.isDir(dir))
			foreach (filename; fs.dirEntries(dir, fs.SpanMode.breadth))
				if (filename.isFile)
				{
					auto file = buildPath(dir, filename);
					if (cachedModuleFiles.binarySearch(file) >= 0)
						continue;
					auto fileMod = moduleNameForFile(file, dir, buffer);
					if (fileMod.startsWith("std"))
					{
						modFileCache[fileMod] = file;
						cachedModuleFiles.insertSorted(file);
					}
					if (fileMod == module_)
						ret ~= file;
				}
	}

	return ret;
}

private string moduleNameForFile(string file, string dir, ref ubyte[] buffer)
{
	auto ret = backend.get!ModulemanComponent.moduleName(
			cast(string) file.readCodeWithBuffer(buffer));
	if (ret.length)
		return ret;
	file = buildNormalizedPath(file);
	dir = buildNormalizedPath(dir);
	if (file.startsWith(dir))
		return file[dir.length .. $].stripExtension.translate(makeTrans("/\\", ".."));
	else
		return baseName(file).stripExtension;
}

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

@protocolNotification("served/killServer")
void killServer()
{
	foreach (instance; backend.instances)
		if (instance.has!DCDComponent)
			instance.get!DCDComponent.killServer();
}

@protocolNotification("served/installDependency")
void installDependency(InstallRequest req)
{
	auto workspaceRoot = selectedWorkspaceRoot;
	injectDependency(workspaceRoot, req);
	if (backend.has!DubComponent)
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
		if (backend.has!DubComponent)
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
	if (backend.has!DubComponent)
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
