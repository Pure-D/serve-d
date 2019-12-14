module served.commands.dcd_update;

import served.extension;
import served.io.git_build;
import served.io.http_wrap;
import served.types;

import workspaced.api;
import workspaced.coms;

import rm.rf;

import std.algorithm : endsWith;
import std.format : format;
import std.json : JSONValue;
import std.path : baseName, buildPath, chainPath, isAbsolute;

import fs = std.file;
import io = std.stdio;

__gshared string dcdUpdateReason = null;
__gshared bool dcdUpdating;
@protocolNotification("served/updateDCD")
void updateDCD()
{
	scope (exit)
	{
		dcdUpdating = false;
		dcdUpdateReason = null;
	}

	if (dcdUpdateReason.length)
		rpc.notifyMethod("coded/logInstall", "Installing DCD: " ~ dcdUpdateReason);
	else
		rpc.notifyMethod("coded/logInstall", "Installing DCD");

	string outputFolder = determineOutputFolder;
	if (fs.exists(outputFolder))
	{
		foreach (file; ["dcd", "DCD", "dcd-client", "dcd-server"])
		{
			auto path = buildPath(outputFolder, file);
			if (fs.exists(path))
			{
				if (fs.isFile(path))
					fs.remove(path);
				else
					rmdirRecurseForce(path);
			}
		}
	}
	if (!fs.exists(outputFolder))
		fs.mkdirRecurse(outputFolder);
	string ext = "";
	version (Windows)
		ext = ".exe";
	string finalDestinationClient;
	string finalDestinationServer;

	bool success;

	enum bundledDCDVersion = "v0.11.1";

	bool compileFromSource = false;
	version (DCDFromSource)
		compileFromSource = true;
	else
	{
		version (Windows)
		{
			// needed to check for 64 bit process compatibility on 32 bit binaries because of WoW64
			import core.sys.windows.windows : GetNativeSystemInfo, SYSTEM_INFO,
				PROCESSOR_ARCHITECTURE_INTEL;

			SYSTEM_INFO sysInfo;
			GetNativeSystemInfo(&sysInfo);
			if (sysInfo.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_INTEL) // only 64 bit releases
				compileFromSource = true;
		}

		if (!checkVersion(bundledDCDVersion, DCDComponent.latestKnownVersion))
			compileFromSource = true;
	}

	string[] triedPaths;

	if (compileFromSource)
	{
		string[] platformOptions;
		version (Windows)
			platformOptions = ["--arch=x86_mscoff"];
		success = compileDependency(outputFolder, "DCD",
				"https://github.com/Hackerpilot/DCD.git", [
					[
						firstConfig.git.userPath, "submodule", "update", "--init",
						"--recursive"
					], ["dub", "build", "--config=client"] ~ platformOptions,
					["dub", "build", "--config=server"] ~ platformOptions
				]);
		finalDestinationClient = buildPath(outputFolder, "DCD", "dcd-client" ~ ext);
		if (!fs.exists(finalDestinationClient))
			finalDestinationClient = buildPath(outputFolder, "DCD", "bin", "dcd-client" ~ ext);
		finalDestinationServer = buildPath(outputFolder, "DCD", "dcd-server" ~ ext);
		if (!fs.exists(finalDestinationServer))
			finalDestinationServer = buildPath(outputFolder, "DCD", "bin", "dcd-server" ~ ext);

		triedPaths = [
			"DCD/dcd-client" ~ ext, "DCD/dcd-server" ~ ext, "DCD/bin/dcd-client" ~ ext,
			"DCD/bin/dcd-server" ~ ext
		];
	}
	else
	{
		string url;

		enum commonPrefix = "https://github.com/dlang-community/DCD/releases/download/"
			~ bundledDCDVersion ~ "/dcd-" ~ bundledDCDVersion;

		version (Windows)
			url = commonPrefix ~ "-windows-x86_64.zip";
		else version (linux)
			url = commonPrefix ~ "-linux-x86_64.tar.gz";
		else version (OSX)
			url = commonPrefix ~ "-osx-x86_64.tar.gz";
		else
			static assert(false);

		import std.process : pipeProcess, Redirect, Config, wait;
		import std.zip : ZipArchive;
		import core.thread : Fiber;

		string destFile = buildPath(outputFolder, url.baseName);

		try
		{
			rpc.notifyMethod("coded/logInstall", "Downloading from " ~ url ~ " to " ~ outputFolder);

			if (fs.exists(destFile))
				rpc.notifyMethod("coded/logInstall",
						"Zip file already exists! Trying to install existing zip.");
			else
				downloadFile(url, "Downloading DCD...", destFile);

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
				auto zip = new ZipArchive(fs.read(destFile));
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

			triedPaths = [
				"dcd-client" ~ ext, "dcd-server" ~ ext, "bin/dcd-client" ~ ext,
				"bin/dcd-server" ~ ext
			];
		}
		catch (Exception e)
		{
			rpc.notifyMethod("coded/logInstall", "Failed installing: " ~ e.toString ~ "\n\n");
			rpc.notifyMethod("coded/logInstall",
					"If you have troube downloading via code-d, try manually downloading the DCD archive and placing it in "
					~ destFile ~ "!");
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
		dcdUpdating = false;

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

				prepareDCD(instance, workspace.folder.uri);
				startDCDServer(instance, workspace.folder.uri);
			}
		}
	}
}
