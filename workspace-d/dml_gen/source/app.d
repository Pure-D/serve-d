import std.file;
import std.conv;
import std.string;

import lookupgen;

void main()
{
	test();

	string prefix = q{//
//
// DO NOT EDIT
//
// This module has been generated automatically from views/dml-completions.txt using `dub run :dml`
//
//
module workspaced.completion.dml;

import workspaced.com.dlangui;

};
	string compStr = "[" ~ generateCompletions(readText("views/dml-completion.txt"))
		.to!(string[]).join(",\n\t") ~ "]";
	string completions = "enum dmlCompletions = " ~ compStr ~ ";";

	write("source/workspaced/completion/dml.d", prefix ~ completions);
}
