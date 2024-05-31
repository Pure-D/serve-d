import std.bitmanip;
import std.conv;
import std.experimental.logger;
import std.file;
import std.functional;
import std.json;
import std.path;
import std.process;
import std.stdio;
import std.string;
import std.uuid;

import core.thread;
import core.thread.fiber;

import served.lsp.filereader;
import served.lsp.jsonops;
import served.lsp.jsonrpc;
import served.lsp.protocol;
import served.lsp.uri;

import tests._basic;

version (assert)
{
}
else
	static assert(false, "Compile with asserts.");

void main()
{
	version (Windows)
		string exe = `..\..\serve-d.exe`;
	else
		string exe = `../../serve-d`;

	globalLogLevel = LogLevel.all;

	foreach (test; [
		new BasicTests(exe)
	])
		test.run();
}
