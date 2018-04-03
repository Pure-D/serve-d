module served.extension;

import core.exception;
import core.thread : Fiber;
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

import served.ddoc;
import served.fibermanager;
import served.types;
import served.translate;

import workspaced.api;
import workspaced.coms;

import served.linters.dub : DubDiagnosticSource;

bool hasDCD, hasDub, hasDscanner;
/// Set to true when shutdown is called
__gshared bool shutdownRequested;

void require(alias val)()
{
	if (!val)
		throw new MethodException(ResponseError(ErrorCode.serverNotInitialized,
				val.stringof[3 .. $] ~ " isn't initialized yet"));
}

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

void changedConfig(string[] paths)
{
	foreach (path; paths)
	{
		switch (path)
		{
		case "d.stdlibPath":
			if (hasDCD)
				dcd.addImports(config.stdlibPath);
			break;
		case "d.projectImportPaths":
			if (hasDCD)
				dcd.addImports(config.d.projectImportPaths);
			break;
		case "d.dubConfiguration":
			if (hasDub)
			{
				auto configs = dub.configurations;
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
							dub.setConfiguration(defaultConfig);
					}
					else
						dub.setConfiguration(configs[0]);
				}
			}
			break;
		case "d.dubArchType":
			if (hasDub && config.d.dubArchType.length
					&& !dub.setArchType(JSONValue(["arch-type" : JSONValue(config.d.dubArchType)])))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.archType"(config.d.dubArchType));
			break;
		case "d.dubBuildType":
			if (hasDub && config.d.dubBuildType.length
					&& !dub.setBuildType(JSONValue(["build-type" : JSONValue(config.d.dubBuildType)])))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.buildType"(config.d.dubBuildType));
			break;
		case "d.dubCompiler":
			if (hasDub && config.d.dubCompiler.length && !dub.setCompiler(config.d.dubCompiler))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.compiler"(config.d.dubCompiler));
			break;
		default:
			break;
		}
	}
}

string[] getPossibleSourceRoots()
{
	import std.file;

	auto confPaths = config.d.projectImportPaths.map!(a => a.isAbsolute ? a
			: buildNormalizedPath(workspaceRoot, a));
	if (!confPaths.empty)
		return confPaths.array;
	auto a = buildNormalizedPath(workspaceRoot, "source");
	auto b = buildNormalizedPath(workspaceRoot, "src");
	if (exists(a))
		return [a];
	if (exists(b))
		return [b];
	return [workspaceRoot];
}

__gshared bool initialStart = true;
InitializeResult initialize(InitializeParams params)
{
	import std.file;

	trace("Initializing serve-d for " ~ params.rootPath);

	initialStart = true;
	crossThreadBroadcastCallback = &handleBroadcast;
	workspaceRoot = params.rootPath;
	chdir(workspaceRoot);
	bool disableDub = config.d.neverUseDub;
	if (!fs.exists(buildPath(workspaceRoot, "dub.json"))
			&& !fs.exists(buildPath(workspaceRoot, "dub.sdl"))
			&& !fs.exists(buildPath(workspaceRoot, "package.json")))
		disableDub = true;
	if (!disableDub)
	{
		trace("Starting dub...");
		hasDub = safe!(dub.startup)(workspaceRoot);
	}
	if (!hasDub)
	{
		if (!disableDub)
		{
			error("Failed starting dub - falling back to fsworkspace");
			rpc.window.showErrorMessage(translate!"d.ext.dubFail");
		}
		try
		{
			fsworkspace.start(workspaceRoot, getPossibleSourceRoots);
		}
		catch (Exception e)
		{
			error(e);
			rpc.window.showErrorMessage(translate!"d.ext.fsworkspaceFail");
		}
	}
	else
		setTimeout({ rpc.notifyMethod("coded/initDubTree"); }, 50);

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

	trace("Starting dmd");
	dmd.start(workspaceRoot, config.d.dmdPath);
	trace("Starting dscanner");
	dscanner.start(workspaceRoot);
	hasDscanner = true;
	trace("Starting dfmt");
	dfmt.start();
	trace("Starting dlangui");
	dlangui.start();
	trace("Starting importer");
	importer.start();
	trace("Starting moduleman");
	moduleman.start(workspaceRoot);

	result.capabilities.codeActionProvider = true;

	return result;
}

@protocolNotification("workspace/didChangeConfiguration")
void configNotify(DidChangeConfigurationParams params)
{
	if (!initialStart)
		return;
	initialStart = false;

	trace("Received configuration");
	startDCD();
	if (!hasDCD || dcd.isOutdated)
	{
		if (config.d.aggressiveUpdate)
			spawnFiber((&updateDCD).toDelegate);
		else
		{
			auto action = translate!"d.ext.compileProgram"("DCD");
			auto res = rpc.window.requestMessage(MessageType.error, translate!"d.served.failDCD"(workspaceRoot,
					config.d.dcdClientPath, config.d.dcdServerPath), [action]);
			if (res == action)
				spawnFiber((&updateDCD).toDelegate);
		}
	}
}

void handleBroadcast(JSONValue data)
{
	auto type = "type" in data;
	if (type && type.type == JSON_TYPE.STRING && type.str == "crash")
	{
		if (data["component"].str == "dcd")
			spawnFiber((&startDCD).toDelegate);
	}
}

void startDCD()
{
	if (shutdownRequested)
		return;
	hasDCD = safe!(dcd.start)(workspaceRoot, config.d.dcdClientPath,
			config.d.dcdServerPath, cast(ushort) 9166, false);
	if (hasDCD)
	{
		trace("Starting dcdext");
		dcdext.start();
		try
		{
			syncYield!(dcd.findAndSelectPort)(cast(ushort) 9166);
			dcd.startServer(config.stdlibPath);
			dcd.refreshImports();
		}
		catch (Exception e)
		{
			rpc.window.showErrorMessage(translate!"d.ext.dcdFail");
			error(e);
			hasDCD = false;
			return;
		}
		info("Imports: ", importPathProvider());
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

@protocolNotification("served/updateDCD")
void updateDCD()
{
	rpc.notifyMethod("coded/logInstall", "Installing DCD");
	string outputFolder = determineOutputFolder;
	if (!fs.exists(outputFolder))
		fs.mkdirRecurse(outputFolder);
	string[] platformOptions;
	version (Windows)
		platformOptions = ["--arch=x86_mscoff"];
	bool success = compileDependency(outputFolder, "DCD", "https://github.com/Hackerpilot/DCD.git", [[config.git.path,
			"submodule", "update", "--init", "--recursive"], ["dub", "build",
			"--config=client"] ~ platformOptions, ["dub", "build", "--config=server"] ~ platformOptions]);
	if (success)
	{
		string ext = "";
		version (Windows)
			ext = ".exe";
		string finalDestinationClient = buildPath(outputFolder, "DCD", "dcd-client" ~ ext);
		if (!fs.exists(finalDestinationClient))
			finalDestinationClient = buildPath(outputFolder, "DCD", "bin", "dcd-client" ~ ext);
		string finalDestinationServer = buildPath(outputFolder, "DCD", "dcd-server" ~ ext);
		if (!fs.exists(finalDestinationServer))
			finalDestinationServer = buildPath(outputFolder, "DCD", "bin", "dcd-server" ~ ext);
		config.d.dcdClientPath = finalDestinationClient;
		config.d.dcdServerPath = finalDestinationServer;
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdClientPath",
				JSONValue(finalDestinationClient), true));
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdServerPath",
				JSONValue(finalDestinationServer), true));
		rpc.notifyMethod("coded/logInstall", "Successfully installed DCD");
		startDCD();
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
				fs.rmdirRecurse(newCwd);
			}
			catch (Exception)
			{
				rpc.notifyMethod("coded/logInstall", "WARNING: Failed to delete " ~ newCwd);
			}
		}
		auto ret = run([config.git.path, "clone", "--recursive", "--depth=1", gitURI, name], cwd);
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
	if (hasDub)
		dub.stop();
	if (hasDCD)
		dcd.stop();
	if (hasDscanner)
		dscanner.stop();
	dmd.stop();
	dfmt.stop();
	dlangui.stop();
	importer.stop();
	moduleman.stop();
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

	Document document = documents[params.textDocument.uri];
	if (document.uri.toLower.endsWith("dscanner.ini"))
	{
		require!hasDscanner;
		auto possibleFields = dscanner.listAllIniFields;
		auto line = document.lineAt(params.position).strip;
		auto defaultList = CompletionList(false, possibleFields.map!(a => CompletionItem(a.name,
				CompletionItemKind.field.opt, Optional!string.init, MarkupContent(a.documentation)
				.opt, Optional!string.init, Optional!string.init, (a.name ~ '=').opt)).array);
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
		if (document.languageId != "d")
			return CompletionList.init;
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
		require!hasDCD;
		auto byteOff = cast(int) document.positionToBytes(params.position);
		JSONValue result;
		joinAll({ result = syncYield!(dcd.listCompletion)(document.text, byteOff); }, {
			if (hasDscanner && !line.strip.length)
			{
				auto result = syncYield!(dscanner.listDefinitions)(uriToFile(params.textDocument.uri),
					document.text);
				if (result.type == JSON_TYPE.NULL)
					return;
				dscanner.DefinitionElement[] defs = result.fromJSON!(dscanner.DefinitionElement[]);
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
		switch (result["type"].str)
		{
		case "identifiers":
			foreach (identifierJson; result["identifiers"].array)
			{
				CompletionItem item;
				info(identifierJson);
				dcd.DCDIdentifier identifier = identifierJson.fromJSON!(dcd.DCDIdentifier);
				item.label = identifier.identifier;
				item.kind = identifier.type.convertFromDCDType;
				if (identifier.documentation.length)
					item.documentation = MarkupContent(identifier.documentation.ddocToMarked);
				if (identifier.definition.length)
				{
					item.detail = identifier.definition;
					item.sortText = identifier.definition;
					// TODO: only add arguments when this is a function call, eg not on template arguments
					if (identifier.type == "f" && config.d.argumentSnippets)
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
			goto case;
		case "calltips":
			return CompletionList(false, completion);
		default:
			throw new Exception("Unexpected result from DCD");
		}
	}
}

@protocolMethod("textDocument/signatureHelp")
SignatureHelp provideSignatureHelp(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return SignatureHelp.init;
	require!hasDCD;
	auto pos = cast(int) document.positionToBytes(params.position);
	auto result = syncYield!(dcd.listCompletion)(document.text, pos);
	SignatureInformation[] signatures;
	int[] paramsCounts;
	SignatureHelp help;
	switch (result["type"].str)
	{
	case "calltips":
		// calltips:[string], symbols:[{file:string, location:number, documentation:string}]
		foreach (i, calltip; result["calltips"].array)
		{
			auto sig = SignatureInformation(calltip.str);
			auto symbols = "symbols" in result;
			if (symbols && symbols.type == JSON_TYPE.ARRAY && i < symbols.array.length)
			{
				auto symbol = symbols.array[i];
				auto doc = "documentation" in symbol;
				if (doc && doc.str.length)
					sig.documentation = MarkupContent(doc.str.ddocToMarked);
			}
			auto funcParams = calltip.str.extractFunctionParameters;

			paramsCounts ~= cast(int) funcParams.length - 1;
			foreach (param; funcParams)
				sig.parameters ~= ParameterInformation(param);

			help.signatures ~= sig;
		}
		auto extractedParams = document.text[0 .. pos].extractFunctionParameters(true);
		help.activeParameter = max(0, cast(int) extractedParams.length - 1);
		size_t[] possibleFunctions;
		foreach (i, count; paramsCounts)
			if (count >= cast(int) extractedParams.length - 1)
				possibleFunctions ~= i;
		help.activeSignature = possibleFunctions.length ? cast(int) possibleFunctions[0] : 0;
		goto case;
	case "identifiers":
		return help;
	default:
		throw new Exception("Unexpected result from DCD");
	}
}

@protocolMethod("workspace/symbol")
SymbolInformation[] provideWorkspaceSymbols(WorkspaceSymbolParams params)
{
	import std.file;

	require!hasDCD;
	auto result = syncYield!(dcd.searchSymbol)(params.query);
	SymbolInformation[] infos;
	TextDocumentManager extraCache;
	foreach (symbol; result.array)
	{
		auto uri = uriFromFile(symbol["file"].str);
		auto doc = documents.tryGet(uri);
		Location location;
		if (!doc.uri)
			doc = extraCache.tryGet(uri);
		if (!doc.uri)
		{
			doc = Document(uri);
			try
			{
				doc.text = readText(symbol["file"].str);
			}
			catch (Exception e)
			{
				error(e);
			}
		}
		if (doc.text)
		{
			location = Location(doc.uri,
					TextRange(doc.bytesToPosition(cast(size_t) symbol["position"].integer)));
			infos ~= SymbolInformation(params.query,
					convertFromDCDSearchType(symbol["type"].str), location);
		}
	}
	return infos;
}

@protocolMethod("textDocument/documentSymbol")
SymbolInformation[] provideDocumentSymbols(DocumentSymbolParams params)
{
	auto document = documents[params.textDocument.uri];
	require!hasDscanner;
	auto result = syncYield!(dscanner.listDefinitions)(uriToFile(params.textDocument.uri),
			document.text);
	if (result.type == JSON_TYPE.NULL)
		return [];
	SymbolInformation[] ret;
	foreach (def; result.array)
	{
		SymbolInformation info;
		info.name = def["name"].str;
		info.location.uri = params.textDocument.uri;
		info.location.range = TextRange(Position(cast(uint) def["line"].integer - 1, 0));
		info.kind = convertFromDscannerType(def["type"].str);
		if (def["type"].str == "f" && def["name"].str == "this")
			info.kind = SymbolKind.constructor;
		const(JSONValue)* ptr;
		auto attribs = def["attributes"];
		if (null !is(ptr = "struct" in attribs) || null !is(ptr = "class" in attribs)
				|| null !is(ptr = "enum" in attribs) || null !is(ptr = "union" in attribs))
			info.containerName = (*ptr).str;
		ret ~= info;
	}
	return ret;
}

@protocolMethod("textDocument/definition")
ArrayOrSingle!Location provideDefinition(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return ArrayOrSingle!Location.init;
	require!hasDCD;
	auto result = syncYield!(dcd.findDeclaration)(document.text,
			cast(int) document.positionToBytes(params.position));
	if (result.type == JSON_TYPE.NULL)
		return ArrayOrSingle!Location.init;
	auto uri = document.uri;
	if (result[0].str != "stdin")
		uri = uriFromFile(result[0].str);
	size_t byteOffset = cast(size_t) result[1].integer;
	Position pos;
	auto found = documents.tryGet(uri);
	if (found.uri)
		pos = found.bytesToPosition(byteOffset);
	else
	{
		string abs = result[0].str;
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
	auto result = syncYield!(dfmt.format)(document.text, args);
	return [TextEdit(TextRange(Position(0, 0),
			document.offsetToPosition(document.text.length)), result.str)];
}

@protocolMethod("textDocument/hover")
Hover provideHover(TextDocumentPositionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return Hover.init;
	require!hasDCD;
	auto docs = syncYield!(dcd.getDocumentation)(document.text,
			cast(int) document.positionToBytes(params.position));
	Hover ret;
	if (docs.type == JSON_TYPE.ARRAY && docs.array.length)
		ret.contents = docs.array.map!(a => a.str.ddocToMarked).join();
	else if (docs.type == JSON_TYPE.STRING && docs.str.length)
		ret.contents = docs.str.ddocToMarked;
	return ret;
}

private auto importRegex = regex(`import\s+(?:[a-zA-Z_]+\s*=\s*)?([a-zA-Z_]\w*(?:\.\w*[a-zA-Z_]\w*)*)?(\s*\:\s*(?:[a-zA-Z_,\s=]*(?://.*?[\r\n]|/\*.*?\*/|/\+.*?\+/)?)+)?;?`);
private auto undefinedIdentifier = regex(
		`^undefined identifier '(\w+)'(?:, did you mean .*? '(\w+)'\?)?$`);
private auto undefinedTemplate = regex(`template '(\w+)' is not defined`);
private auto noProperty = regex(`^no property '(\w+)'(?: for type '.*?')?$`);
private auto moduleRegex = regex(`module\s+([a-zA-Z_]\w*\s*(?:\s*\.\s*[a-zA-Z_]\w*)*)\s*;`);
private auto whitespace = regex(`\s*`);

@protocolMethod("textDocument/codeAction")
Command[] provideCodeActions(CodeActionParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	Command[] ret;
	if (hasDCD) // check if extends
	{
		auto startIndex = document.positionToBytes(params.range.start);
		ptrdiff_t idx = min(cast(ptrdiff_t) startIndex, cast(ptrdiff_t) document.text.length - 1);
		while (idx > 0)
		{
			if (document.text[idx] == ':')
			{
				// probably extends
				if (syncYield!(dcdext.implement)(document.text, cast(int) startIndex).str.strip.length > 0)
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
			if (diagnostic.message.canFind("import "))
			{
				if (!match)
					continue;
				ret ~= Command("Import " ~ match[1], "code-d.addImport",
						[JSONValue(match[1]), JSONValue(document.positionToOffset(params.range[0]))]);
			}
			else /*if (cast(bool)(match = diagnostic.message.matchFirst(undefinedIdentifier))
					|| cast(bool)(match = diagnostic.message.matchFirst(undefinedTemplate))
					|| cast(bool)(match = diagnostic.message.matchFirst(noProperty)))*/
			{
				// temporary fix for https://issues.dlang.org/show_bug.cgi?id=18565
				string[] files;
				string[] modules;
				int lineNo;
				match = diagnostic.message.matchFirst(undefinedIdentifier);
				if (match)
					goto start;
				match = diagnostic.message.matchFirst(undefinedTemplate);
				if (match)
					goto start;
				match = diagnostic.message.matchFirst(noProperty);
				if (match)
					goto start;
				goto noMatch;
			start:
				joinAll({
					if (hasDscanner)
						files ~= syncYield!(dscanner.findSymbol)(match[1]).array.map!"a[`file`].str".array;
				}, {
					if (hasDCD)
						files ~= syncYield!(dcd.searchSymbol)(match[1]).array.map!"a[`file`].str".array;
				});
				foreach (file; files.sort().uniq)
				{
					if (!isAbsolute(file))
						file = buildNormalizedPath(workspaceRoot, file);
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
			noMatch:
			}
		}
		else
		{
			import analysis.imports_sortedness : ImportSortednessCheck;

			if (diagnostic.message == ImportSortednessCheck.MESSAGE)
			{
				ret ~= Command("Sort imports", "code-d.sortImports",
						[JSONValue(document.positionToOffset(params.range[0]))]);
			}
		}
	}
	return ret;
}

@protocolMethod("textDocument/codeLens")
CodeLens[] provideCodeLens(CodeLensParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	CodeLens[] ret;
	if (config.d.enableDMDImportTiming)
		foreach (match; document.text.matchAll(importRegex))
		{
			size_t index = match.pre.length;
			auto pos = document.bytesToPosition(index);
			ret ~= CodeLens(TextRange(pos), Optional!Command.init, JSONValue(["type"
					: JSONValue("importcompilecheck"), "code" : JSONValue(match.hit),
					"module" : JSONValue(match[1])]));
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
		auto code = "code" in lens.data;
		if (!code || code.type != JSON_TYPE.STRING || !code.str.length)
			throw new Exception("No valid code provided");
		auto module_ = "module" in lens.data;
		if (!module_ || module_.type != JSON_TYPE.STRING || !module_.str.length)
			throw new Exception("No valid module provided");
		int decMs = getImportCompilationTime(code.str, module_.str);
		lens.command = Command((decMs < 10 ? "no noticable effect"
				: "~" ~ decMs.to!string ~ "ms") ~ " for importing this");
		return lens;
	default:
		throw new Exception("Unknown lens type");
	}
}

int getImportCompilationTime(string code, string module_)
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
		if (now - exist.at < (exist.ret >= 500 ? 10.minutes : exist.ret >= 30
				? 60.seconds : 20.seconds) || module_.startsWith("std."))
			return exist.ret;
		else
		{
			cache[i] = cache[$ - 1];
			cache.length--;
		}
	}

	// run blocking so we don't compute multiple in parallel
	auto ret = dmd.measureSync(code, null, 20, 500);
	if (!ret.success)
		throw new Exception("Compilation failed");
	auto msecs = cast(int) round(ret.duration.total!"msecs" / 5.0) * 5;
	cache ~= CompileCache(now, code, msecs);
	return msecs;
}

@protocolMethod("served/listConfigurations")
string[] listConfigurations()
{
	require!hasDub;
	return dub.configurations;
}

@protocolMethod("served/switchConfig")
bool switchConfig(string value)
{
	require!hasDub;
	return dub.setConfiguration(value);
}

@protocolMethod("served/getConfig")
string getConfig(string value)
{
	require!hasDub;
	return dub.configuration;
}

@protocolMethod("served/listArchTypes")
string[] listArchTypes()
{
	require!hasDub;
	return dub.archTypes;
}

@protocolMethod("served/switchArchType")
bool switchArchType(string value)
{
	require!hasDub;
	return dub.setArchType(JSONValue(["arch-type" : JSONValue(value)]));
}

@protocolMethod("served/getArchType")
string getArchType(string value)
{
	require!hasDub;
	return dub.archType;
}

@protocolMethod("served/listBuildTypes")
string[] listBuildTypes()
{
	require!hasDub;
	return dub.buildTypes;
}

@protocolMethod("served/switchBuildType")
bool switchBuildType(string value)
{
	require!hasDub;
	return dub.setBuildType(JSONValue(["build-type" : JSONValue(value)]));
}

@protocolMethod("served/getBuildType")
string getBuildType()
{
	require!hasDub;
	return dub.buildType;
}

@protocolMethod("served/getCompiler")
string getCompiler()
{
	require!hasDub;
	return dub.compiler;
}

@protocolMethod("served/switchCompiler")
bool switchCompiler(string value)
{
	require!hasDub;
	return dub.setCompiler(value);
}

@protocolMethod("served/addImport")
auto addImport(AddImportParams params)
{
	auto document = documents[params.textDocument.uri];
	return importer.add(params.name.idup, document.text, params.location, params.insertOutermost);
}

@protocolMethod("served/sortImports")
TextEdit[] sortImports(SortImportsParams params)
{
	auto document = documents[params.textDocument.uri];
	TextEdit[] ret;
	auto sorted = importer.sortImports(document.text,
			cast(int) document.offsetToBytes(params.location));
	if (sorted == importer.ImportBlock.init)
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

	require!hasDCD;
	auto document = documents[params.textDocument.uri];
	TextEdit[] ret;
	auto location = document.offsetToBytes(params.location);
	auto code = syncYield!(dcdext.implement)(document.text, cast(int) location).str.strip;
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
	require!hasDCD;
	syncYield!(dcd.restartServer);
	return true;
}

@protocolMethod("served/updateImports")
bool updateImports()
{
	bool success;
	if (hasDub)
	{
		success = syncYield!(dub.update).type == JSON_TYPE.TRUE;
		if (success)
			rpc.notifyMethod("coded/updateDubTree");
	}
	require!hasDCD;
	dcd.refreshImports();
	return success;
}

@protocolMethod("served/listDependencies")
DubDependency[] listDependencies(string packageName)
{
	require!hasDub;
	DubDependency[] ret;
	auto allDeps = dub.dependencies;
	if (!packageName.length)
	{
		auto deps = dub.rootDependencies;
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

// === Protocol Notifications starting here ===

struct FileOpenInfo
{
	SysTime at;
}

__gshared FileOpenInfo[string] freshlyOpened;

@protocolNotification("workspace/didChangeWatchedFiles")
void onChangeFiles(DidChangeWatchedFilesParams params)
{
	info(params);

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
				// Sending applyEdit so it is undoable
				auto patches = moduleman.normalizeModules(file.uriToFile, document.text);
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

@protocolNotification("textDocument/didOpen")
void onDidOpenDocument(DidOpenTextDocumentParams params)
{
	freshlyOpened[params.textDocument.uri] = FileOpenInfo(Clock.currTime);

	info(freshlyOpened);
}

int changeTimeout;
@protocolNotification("textDocument/didChange")
void onDidChangeDocument(DocumentLinkParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return;
	int delay = document.text.length > 50 * 1024 ? 1000 : 200; // be slower after 50KiB
	if (hasDscanner)
	{
		clearTimeout(changeTimeout);
		changeTimeout = setTimeout({
			import served.linters.dscanner;

			lint(document);
			// Delay to avoid too many requests
		}, delay);
	}
}

@protocolNotification("textDocument/didSave")
void onDidSaveDocument(DidSaveTextDocumentParams params)
{
	auto document = documents[params.textDocument.uri];
	auto fileName = params.textDocument.uri.uriToFile.baseName;

	if (document.languageId == "d" || document.languageId == "diet")
	{
		if (!config.d.enableLinting)
			return;
		joinAll({
			if (hasDscanner && config.d.enableStaticLinting)
			{
				if (document.languageId == "diet")
					return;
				import served.linters.dscanner;

				lint(document);
			}
		}, {
			if (hasDub && config.d.enableDubLinting)
			{
				import served.linters.dub;

				lint(document);
			}
		});
	}
	else if (fileName == "dub.json" || fileName == "dub.sdl")
	{
		info("Updating dependencies");
		rpc.window.runOrMessage(dub.upgrade(), MessageType.warning, translate!"d.ext.dubUpgradeFail");
		rpc.window.runOrMessage(dub.updateImportPaths(true), MessageType.warning,
				translate!"d.ext.dubImportFail");
		rpc.notifyMethod("coded/updateDubTree");
	}
}

@protocolNotification("served/killServer")
void killServer()
{
	dcd.killServer();
}

@protocolNotification("served/installDependency")
void installDependency(InstallRequest req)
{
	injectDependency(req);
	if (hasDub)
	{
		dub.upgrade();
		dub.updateImportPaths(true);
	}
	updateImports();
}

@protocolNotification("served/updateDependency")
void updateDependency(UpdateRequest req)
{
	if (changeDependency(req))
	{
		if (hasDub)
		{
			dub.upgrade();
			dub.updateImportPaths(true);
		}
		updateImports();
	}
}

@protocolNotification("served/uninstallDependency")
void uninstallDependency(UninstallRequest req)
{
	removeDependency(req.name);
	if (hasDub)
	{
		dub.upgrade();
		dub.updateImportPaths(true);
	}
	updateImports();
}

void injectDependency(InstallRequest req)
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

bool changeDependency(UpdateRequest req)
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

bool removeDependency(string name)
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
