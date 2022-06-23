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
	{
		size_t lastIndex = size_t.max;
		Position lastPosition;

		foreach (match; document.rawText.matchAll(importRegex))
		{
			size_t index = match.pre.length;
			auto pos = document.movePositionBytes(lastPosition, lastIndex, index);
			lastIndex = index;
			lastPosition = pos;

			ret ~= CodeLens(TextRange(pos), Optional!Command.init,
					JsonValue([
						"type": JsonValue("importcompilecheck"),
						"code": JsonValue(match.hit.idup),
						"module": JsonValue(match[1].idup),
						"file": JsonValue(file)
					]).opt);
		}
	}
	return ret;
}

@protocolMethod("codeLens/resolve")
CodeLens resolveCodeLens(CodeLens lens)
{
	if (lens.data.isNone ||
		lens.data.deref.kind != JsonValue.Kind.object)
		throw new Exception("Invalid Lens Object");

	auto lensData = lens.data.deref.get!(StringMap!JsonValue);
	auto type = lensData.get("type", JsonValue(""))
		.match!((string s) => s, _ => "");
	switch (type)
	{
	case "importcompilecheck":
		try
		{
			auto code = lensData.get("code", JsonValue(null))
				.match!((string s) => s, _ => "");
			if (!code.length)
				throw new Exception("No valid code provided");

			auto module_ = lensData.get("module", JsonValue(null))
				.match!((string s) => s, _ => "");
			if (!module_.length)
				throw new Exception("No valid module provided");

			auto file = lensData.get("file", JsonValue(null))
				.match!((string s) => s, _ => "");
			if (!file.length)
				throw new Exception("No valid file provided");

			int decMs = getImportCompilationTime(code, module_, file);
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
