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
import std.path : baseName, buildPath, chainPath, isAbsolute;
import std.process : execute;

import fs = std.file;
import io = std.stdio;


version (Win32)
{
	version (X86_64)
	{
		// wat
	}
	else version (X86)
	{
		version = RuntimeSourceCheck;
		// check for WoW64
		bool isDCDFromSource()
		{
			// needed to check for 64 bit process compatibility on 32 bit binaries because of WoW64
			import core.sys.windows.windows : GetNativeSystemInfo, PROCESSOR_ARCHITECTURE_AMD64, PROCESSOR_ARCHITECTURE_IA64, SYSTEM_INFO;

			SYSTEM_INFO sysInfo;
			GetNativeSystemInfo(&sysInfo);
			// only 64 bit releases
			return sysInfo.wProcessorArchitecture != PROCESSOR_ARCHITECTURE_AMD64
				&& sysInfo.wProcessorArchitecture != PROCESSOR_ARCHITECTURE_IA64;
		}
	}
	else version = DCDFromSource;
}
else version (X86_64)
{
	version (Win64)
	{
	}
	else version (linux)
	{
	}
	else version (OSX)
	{
	}
	else version = DCDFromSource;
}
else version (AArch64)
{
	version (OSX)
	{
	}
	else version = DCDFromSource;
}
else
{
	version = DCDFromSource;
}

version (RuntimeSourceCheck) {}
else
{
	version (DCDFromSource)
		enum isDCDFromSource = true;
	else
		enum isDCDFromSource = false;
}

version (Windows)
{
	import core.sys.windows.basetsd : HANDLE;
	import core.sys.windows.windef : DWORD, LPWSTR;
	import core.sys.windows.winbase : CloseHandle, GetCurrentProcessId, OpenProcess,
		TerminateProcess, INVALID_HANDLE_VALUE;
	import core.sys.windows.winnt : PROCESS_QUERY_INFORMATION, PROCESS_TERMINATE;
	import core.sys.windows.tlhelp32 : CreateToolhelp32Snapshot, Process32FirstW,
		Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS;

	extern(Windows) int QueryFullProcessImageNameW(HANDLE process, DWORD flags,
		LPWSTR buffer, DWORD* size);

	/// Windows locks running .exe files, so stop any dcd-server started from
	/// `folder` before its binaries are replaced.
	private void killDCDServersIn(string folder)
	{
		import std.string : icmp;
		import std.utf : toUTF8;

		enum processName = "dcd-server.exe";

		auto snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
		if (snapshot == INVALID_HANDLE_VALUE)
			return;
		scope (exit) CloseHandle(snapshot);

		PROCESSENTRY32W entry;
		entry.dwSize = cast(typeof(entry.dwSize)) PROCESSENTRY32W.sizeof;
		if (!Process32FirstW(snapshot, &entry))
			return;

		do
		{
			if (entry.th32ProcessID == GetCurrentProcessId())
				continue;

			auto process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_TERMINATE,
				0, entry.th32ProcessID);
			if (!process)
				continue;
			scope (exit) CloseHandle(process);

			wchar[1024] buffer;
			DWORD size = cast(DWORD) buffer.length;
			if (!QueryFullProcessImageNameW(process, 0, buffer.ptr, &size)
					|| size < processName.length)
				continue;

			auto exePath = buffer[0 .. size].toUTF8;
			if (exePath.length >= folder.length
					&& exePath.length >= processName.length
					&& icmp(exePath[0 .. folder.length], folder) == 0
					&& icmp(exePath[$ - processName.length .. $], processName) == 0)
				TerminateProcess(process, 1);
		}
		while (Process32NextW(snapshot, &entry));
	}
}

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
	void removeOldDCD()
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
	if (fs.exists(outputFolder))
	{
		version (Windows)
		{
			import core.thread : Thread;
			import core.time : msecs;

			killDCDServersIn(outputFolder);
			foreach (attempt; 0 .. 10)
			{
				try
				{
					removeOldDCD();
					break;
				}
				catch (Exception e)
				{
					if (attempt == 9)
						throw e;
					Thread.sleep(250.msecs);
				}
			}
		}
		else
			removeOldDCD();
	}
	if (!fs.exists(outputFolder))
		fs.mkdirRecurse(outputFolder);
	string ext = "";
	version (Windows)
		ext = ".exe";
	string finalDestinationClient;
	string finalDestinationServer;

	bool success;

	enum latestReleaseBinaryBroken = false;

	// download the exact version serve-d was built against so the two can't drift
	enum bundledDCDVersion = "v" ~ format!"%(%s.%)"(DCDComponent.latestKnownVersion);

	bool compileFromSource = isDCDFromSource || latestReleaseBinaryBroken;
	if (!compileFromSource
		&& !checkVersion(bundledDCDVersion, DCDComponent.latestKnownVersion))
		compileFromSource = true;

	string[] triedPaths;

	if (compileFromSource)
	{
		success = compileDependency(outputFolder, "DCD",
				"https://github.com/dlang-community/DCD.git", [
					[
						anyConfig.git.userPath, "submodule", "update", "--init",
						"--recursive"
					], ["dub", "build", "--config=client"],
					["dub", "build", "--config=server"]
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
		{
			version (AArch64)
				url = commonPrefix ~ "-osx-aarch64.tar.gz";
			else
				url = commonPrefix ~ "-osx-x86_64.tar.gz";
		}

		if (!url.length)
			assert(false, "this branch should not be reachable on this platform");

		import core.thread : Fiber;
		import std.process : Config, pipeProcess, Redirect, wait;
		import std.zip : ZipArchive;

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
		success = false;
	}

	if (success)
	{
		auto resServer = execute([finalDestinationServer, "--version"]);
		if (resServer.status != 0)
		{
			rpc.notifyMethod("coded/logInstall",
					"Successfully downloaded DCD, but trying to run `"
					~ finalDestinationServer ~ " --version` failed:");
			rpc.notifyMethod("coded/logInstall", resServer.output);
			success = false;
		}
	}

	if (!success)
	{
		finalDestinationClient = "dcd-client";
		finalDestinationServer = "dcd-server";
	}

	rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdClientPath",
			JsonValue(finalDestinationClient), true));
	rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdServerPath",
			JsonValue(finalDestinationServer), true));

	if (success)
	{
		rpc.notifyMethod("coded/logInstall", "Successfully installed DCD");

		backend.globalConfiguration.set("dcd", "clientPath", finalDestinationClient);
		backend.globalConfiguration.set("dcd", "serverPath", finalDestinationServer);

		foreach (ref workspace; workspaces)
		{
			workspace.config.d.dcdClientPath = finalDestinationClient;
			workspace.config.d.dcdServerPath = finalDestinationServer;
		}

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

				lazyStartDCDServer(instance, workspace.folder.uri);
			}
		}
	}
	else
	{
		rpc.notifyMethod("coded/logInstall", "DCD install failed");
	}
}
