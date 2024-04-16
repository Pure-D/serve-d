/**
 * Entry-point to serve-d
 *
 * Replaces std.stdio stdout with stderr so writeln calls don't accidentally
 * write to the RPC output.
 *
 * Handles all command line arguments, possibly modifying global state variables
 * when enabling serve-d specific protocol extensions are requested.
 *
 * Handles all the request/notification dispatch, calls (de)serialization of
 * given JSON parameters and return values and responds back to the RPC.
 *
 * Performs periodic GC cleanup and invokes the fiber scheduler, pushing
 * incoming RPC requests as tasks to the fiber scheduler.
 */
module app;

import core.thread;
import core.sync.mutex;

import fs = std.file;
import io = std.stdio;
import std.algorithm;
import std.conv;
import std.datetime.stopwatch;
import std.experimental.logger;
import std.functional;
import std.getopt;
import std.json;
import std.path;
import std.string;
import std.traits;

import served.io.http_wrap;
import served.lsp.filereader;
import served.lsp.jsonrpc;
import served.types;
import served.utils.fibermanager;
import served.utils.trace;
import served.utils.translate;

static import served.extension;

void printVersion(io.File output = io.stdout)
{
	import Compiler = std.compiler;
	import OS = std.system;

	import served.info;

	output.writefln("serve-d standalone v%(%s.%)%s", Version,
			VersionSuffix.length ? text('-', VersionSuffix) : VersionSuffix);
	output.writefln("Included features: %(%s, %)", IncludedFeatures);
	// There will always be a line which starts with `Built: ` forever, it is considered stable. If there is no line, assume version 0.1.2
	output.writefln("Built: %s", __TIMESTAMP__);

	version (AArch64)
		string arch = "aarch64";
	else version (ARM)
		string arch = "arm";
	else version (X86_64)
		string arch = "x86_64";
	else version (X86)
		string arch = "x86";
	else version (PPC64)
		string arch = "ppc64";
	else version (PPC)
		string arch = "ppc";
	else
		string arch = "unknown arch";
	output.writeln("with compiler ", Compiler.name, " v",
			Compiler.version_major.to!string, ".", Compiler.version_minor.to!string,
			" on ", OS.os.to!string, " ", arch);
	output.writefln(BundledDependencies);
}

int main(string[] args)
{
	debug globalLogLevel = LogLevel.trace;
	else globalLogLevel = LogLevel.info;

	static if (__VERSION__ < 2101)
		sharedLog = new FileLogger(io.stderr);
	else
		sharedLog = (() @trusted => cast(shared) new FileLogger(io.stderr))();

	bool printVer;
	string[] features;
	string[] provides;
	string lang = "en";
	bool wait;

	void setLogLevel(string option, string level)
	{
		switch (level)
		{
			static foreach (levelName; __traits(allMembers, LogLevel))
			{
		case levelName:
				globalLogLevel = __traits(getMember, LogLevel, levelName);
				return;
			}
		default:
			throw new GetOptException(
					"Unknown value for log level, supported values: "
					~ [__traits(
							allMembers, LogLevel)].join(", "));
		}
	}

	void setLogFile(string option, string file)
	{
		auto fileLogger = new FileLogger(file, LogLevel.all, CreateFolder.no);
		static if (__VERSION__ < 2101)
			sharedLog = fileLogger;
		else
			sharedLog = (() @trusted => cast(shared) fileLogger)();
	}

	//dfmt off
	auto argInfo = args.getopt(
		"r|require", "Adds a feature set that is required. Unknown feature sets will intentionally crash on startup",
			&features,
		"p|provide", "Features to let the editor handle for better integration", &provides,
		"v|version", "Print version of program", &printVer,
		"logfile", "Output all log into the given file instead of stderr", &setLogFile,
		"loglevel", "Change the log level for output logging (" ~ [__traits(allMembers, LogLevel)].join("|") ~ ")",
			&setLogLevel,
		"lang", "Change the language of GUI messages", &lang,
		"wait", "Wait for a second before starting (for debugging)", &wait);
	//dfmt on
	if (wait)
		Thread.sleep(2.seconds);
	if (argInfo.helpWanted)
	{
		if (printVer)
			printVersion();
		defaultGetoptPrinter("workspace-d / vscode-language-server bridge", argInfo.options);
		return 0;
	}
	if (printVer)
	{
		printVersion();
		return 0;
	}

	if (lang.length >= 2) // ja-JP -> ja, en-GB -> en, etc
		currentLanguage = lang[0 .. 2];
	if (currentLanguage != "en")
		info("Setting language to ", currentLanguage);

	foreach (feature; features)
		if (!IncludedFeatures.canFind(feature.toLower.strip))
		{
			io.stderr.writeln();
			io.stderr.writeln(
					"FATAL: Extension-requested feature set '" ~ feature
					~ "' is not in this version of serve-d!");
			io.stderr.writeln("---");
			io.stderr.writeln("HINT: Maybe serve-d is outdated?");
			io.stderr.writeln();
			return 1;
		}
	trace("Features fulfilled");

	foreach (provide; provides)
	{
		// don't forget to update README.md if adding stuff!
		switch (provide)
		{
		case "http":
			letEditorDownload = true;
			trace("Interactive HTTP downloads handled via editor");
			break;
		case "implement-snippets":
			import served.commands.code_actions : implementInterfaceSnippets;

			implementInterfaceSnippets = true;
			trace("Auto-implement interface supports snippets");
			break;
		case "context-snippets":
			import served.commands.complete : doCompleteSnippets;

			doCompleteSnippets = true;
			trace("Context snippets handled by serve-d");
			break;
		case "default-snippets":
			import served.extension : registerDefaultSnippets;

			registerDefaultSnippets = true;
			trace("Some dependency snippets will be registered by serve-d");
			break;
		case "test-runner":
			import served.commands.test_provider : doTrackTests;

			doTrackTests = true;
			trace("Discoverying & emitting unittests for language client");
			break;
		case "tasks-current":
			import served.commands.dub : useBuildTaskDollarCurrent;

			useBuildTaskDollarCurrent = true;
			trace("Using `$current` in build tasks");
			break;
		case "async-ask-load":
			import served.extension : bundleAskLoads;

			bundleAskLoads = true;
			trace("Bundling consecutive ManyProjectsAction.ask loads into a single async notification (skips load meanwhile)");
			break;
		default:
			warningf("Unknown --provide flag '%s' provided. Maybe serve-d is outdated?", provide);
			break;
		}
	}

	printVersion(io.stderr);

	auto ret = lspRouter.run() ? 0 : 1;
	version (Posix)
	{
		import core.stdc.stdlib;

		// exit without cleaning up (because of segfault in GC cleanup + OS cleans up for us)
		exit(ret);
	}
	else
		return ret;
}
