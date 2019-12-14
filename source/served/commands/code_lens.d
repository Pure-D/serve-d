module served.commands.code_lens;

import served.commands.code_actions;

import served.extension;
import served.types;
import served.utils.fibermanager;

import workspaced.api;
import workspaced.coms;

import core.time : minutes, msecs;

import std.algorithm : startsWith;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.datetime.systime : Clock, SysTime;
import std.json : JSONType, JSONValue;
import std.regex : matchAll;

@protocolMethod("textDocument/codeLens")
CodeLens[] provideCodeLens(CodeLensParams params)
{
	auto document = documents[params.textDocument.uri];
	string file = document.uri.uriToFile;
	if (document.languageId != "d")
		return [];
	CodeLens[] ret;
	if (workspace(params.textDocument.uri).config.d.enableDMDImportTiming)
		foreach (match; document.rawText.matchAll(importRegex))
		{
			size_t index = match.pre.length;
			auto pos = document.bytesToPosition(index);
			ret ~= CodeLens(TextRange(pos), Optional!Command.init,
					JSONValue([
							"type": JSONValue("importcompilecheck"),
							"code": JSONValue(match.hit),
							"module": JSONValue(match[1]),
							"file": JSONValue(file)
						]));
		}
	return ret;
}

@protocolMethod("codeLens/resolve")
CodeLens resolveCodeLens(CodeLens lens)
{
	if (lens.data.type != JSONType.object)
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
			if (!code || code.type != JSONType.string || !code.str.length)
				throw new Exception("No valid code provided");
			auto module_ = "module" in lens.data;
			if (!module_ || module_.type != JSONType.string || !module_.str.length)
				throw new Exception("No valid module provided");
			auto file = "file" in lens.data;
			if (!file || file.type != JSONType.string || !file.str.length)
				throw new Exception("No valid file provided");
			int decMs = getImportCompilationTime(code.str, module_.str, file.str);
			lens.command = Command((decMs < 10
					? "no noticable effect" : "~" ~ decMs.to!string ~ "ms") ~ " for importing this");
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
int getImportCompilationTime(string code, string module_, string file)
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
	auto ret = backend.best!DMDComponent(file).measureSync(code, null, 20, 500);
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
