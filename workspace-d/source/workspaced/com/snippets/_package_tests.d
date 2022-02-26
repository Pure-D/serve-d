module workspaced.com.snippets._package_tests;

import std.conv;

import workspaced.api;
import workspaced.com.dfmt;
import workspaced.com.snippets;
import workspaced.helpers;

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!SnippetsComponent;
	backend.register!DfmtComponent;
	SnippetsComponent snippets = backend.get!SnippetsComponent(workspace.directory);

	auto args = ["--indent_style", "tab"];

	auto res = snippets.formatSync("void main(${1:string[] args}) {\n\t$0\n}", args);
	assert(res == "void main(${1:string[] args})\n{\n\t$0\n}");

	res = snippets.formatSync("class ${1:MyClass} {\n\t$0\n}", args);
	assert(res == "class ${1:MyClass}\n{\n\t$0\n}");

	res = snippets.formatSync("enum ${1:MyEnum} = $2;\n$0", args);
	assert(res == "enum ${1:MyEnum} = $2;\n$0");

	res = snippets.formatSync("import ${1:std};\n$0", args);
	assert(res == "import ${1:std};\n$0");

	res = snippets.formatSync("import ${1:std};\n$0", args, SnippetLevel.method);
	assert(res == "import ${1:std};\n$0");

	res = snippets.formatSync("foo(delegate() {\n${1:// foo}\n});", args, SnippetLevel.method);
	assert(res == "foo(delegate() {\n\t${1:// foo}\n});");

	res = snippets.formatSync(`auto ${1:window} = new SimpleWindow(Size(${2:800, 600}), "$3");`, args, SnippetLevel.method);
	assert(res == `auto ${1:window} = new SimpleWindow(Size(${2:800, 600}), "$3");`);
}

unittest
{
	import workspaced.helpers;

	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!SnippetsComponent;
	SnippetsComponent snippets = backend.get!SnippetsComponent(workspace.directory);

	runTestDataFileTests("test/data/snippet_info", null, null,
		(code, parts, line) {
			assert(parts.length == 2, "malformed snippet info test line: " ~ line);

			auto i = snippets.determineSnippetInfo(null, code, parts[0].to!int);
			assert(i.level == parts[1].to!SnippetLevel, i.stack.to!string);
		}, null);
}