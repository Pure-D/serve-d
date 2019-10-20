#!/usr/bin/env rdmd

import std.algorithm;
import std.exception;
import std.file;
import std.json;
import std.process;
import std.stdio;
import std.string;

void main()
{
	version (Windows)
		string served = ".\\serve-d.exe";
	else
		string served = "./serve-d";

	auto res = execute([served, "--version"]);
	enforce(res.status == 0, "serve-d --version didn't return status 0");

	string output = res.output.strip;
	enforce(output.startsWith("serve-d v"), "serve-d --version didn't begin with `serve-d v`");
	output = output["serve-d v".length .. $];

	auto space = output.indexOfAny(" \t\r\n");
	if (space != -1)
		output = output[0 .. space];

	string tag = getExpectedTag();
	enforce(tag == output, "Tag was named " ~ tag ~ " but serve-d reported version " ~ output);
	writeln("serve-d version is ", output, ", same as released.");
}

string getExpectedTag()
{
	string event = environment["GITHUB_EVENT_PATH"];
	auto obj = parseJSON(readText(event).strip);
	enforce(obj.type == JSONType.object && "release" in obj.object,
			"Not a release event (how did this script even get called at this point?!)");

	auto release = obj.object["release"];
	auto tag = *enforce("tag_name" in release);
	enforce(tag.type == JSONType.string);

	string ret = tag.str;
	if (ret.startsWith("v"))
		ret = ret[1 .. $];

	return ret;
}
