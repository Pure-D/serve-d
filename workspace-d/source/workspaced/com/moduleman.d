module workspaced.com.moduleman;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.format;
import std.functional;
import std.path;
import std.string;

import workspaced.api;

@component("moduleman")
class ModulemanComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		config.stringBehavior = StringBehavior.source;
	}

	/// Renames a module to something else (only in the project root).
	/// Params:
	/// 	renameSubmodules: when `true`, this will rename submodules of the module too. For example when renaming `lib.com` to `lib.coms` this will also rename `lib.com.*` to `lib.coms.*`
	/// Returns: all changes that need to happen to rename the module. If no module statement could be found this will return an empty array.
	FileChanges[] rename(string mod, string rename, bool renameSubmodules = true)
	{
		if (!refInstance)
			throw new Exception("moduleman.rename requires to be instanced");

		RollbackAllocator rba;
		FileChanges[] changes;
		bool foundModule = false;
		auto from = mod.split('.');
		auto to = rename.split('.');
		foreach (file; dirEntries(instance.cwd, SpanMode.depth))
		{
			if (file.extension != ".d")
				continue;
			string code = readText(file);
			auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
			auto parsed = parseModule(tokens, file, &rba);
			auto reader = new ModuleChangerVisitor(file, from, to, renameSubmodules);
			reader.visit(parsed);
			if (reader.changes.replacements.length)
				changes ~= reader.changes;
			if (reader.foundModule)
				foundModule = true;
		}
		if (!foundModule)
			return [];
		return changes;
	}

	/// Renames/adds/removes a module from a file to match the majority of files in the folder.
	/// Params:
	/// 	file: File path to the file to normalize
	/// 	code: Current code inside the text buffer
	CodeReplacement[] normalizeModules(scope const(char)[] file, scope const(char)[] code)
	{
		if (!refInstance)
			throw new Exception("moduleman.normalizeModules requires to be instanced");

		int[string] modulePrefixes;
		modulePrefixes[""] = 0;
		auto modName = file.replace("\\", "/").stripExtension;
		if (modName.baseName == "package")
			modName = modName.dirName;
		if (modName.startsWith(instance.cwd.replace("\\", "/")))
			modName = modName[instance.cwd.length .. $];
		modName = modName.stripLeft('/');
		auto longest = modName;
		foreach (imp; importPaths)
		{
			imp = imp.replace("\\", "/");
			if (imp.startsWith(instance.cwd.replace("\\", "/")))
				imp = imp[instance.cwd.length .. $];
			imp = imp.stripLeft('/');
			if (longest.startsWith(imp))
			{
				auto shortened = longest[imp.length .. $];
				if (shortened.length < modName.length)
					modName = shortened;
			}
		}
		auto sourcePos = (modName ~ '/').indexOf("/source/");
		if (sourcePos != -1)
			modName = modName[sourcePos + "/source".length .. $];
		modName = modName.stripLeft('/').replace("/", ".");
		if (!modName.length)
			return [];
		auto existing = describeModule(code);
		if (modName == existing.moduleName)
		{
			return [];
		}
		else
		{
			if (modName == "")
			{
				return [CodeReplacement([existing.outerFrom, existing.outerTo], "")];
			}
			else
			{
				const trailing = code[min(existing.outerTo, $) .. $];
				// determine number of new lines to insert after full module name + semicolon
				string semicolonNewlines = trailing.startsWith("\n\n", "\r\r", "\r\n\r\n") ? ";"
					: trailing.startsWith("\n", "\r") ? ";\n"
					: ";\n\n";
				return [
					CodeReplacement([existing.outerFrom, existing.outerTo], text("module ",
							modName, (existing.outerTo == existing.outerFrom ? semicolonNewlines : ";")))
				];
			}
		}
	}

	/// Returns the module name parts of a D code
	const(string)[] getModule(scope const(char)[] code)
	{
		return describeModule(code).raw;
	}

	/// Returns the normalized module name as string of a D code
	string moduleName(scope const(char)[] code)
	{
		return describeModule(code).moduleName;
	}

	///
	FileModuleInfo describeModule(scope const(char)[] code)
	{
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		ptrdiff_t start = -1;
		size_t from, to;
		size_t outerFrom, outerTo;

		foreach (i, Token t; tokens)
		{
			if (t.type == tok!"module")
			{
				start = i;
				outerFrom = t.index;
				break;
			}
		}

		if (start == -1)
		{
			FileModuleInfo ret;
			start = 0;
			if (tokens.length && tokens[0].type == tok!"scriptLine")
			{
				start = code.indexOfAny("\r\n");
				if (start == -1)
				{
					start = 0;
				}
				else
				{
					if (start + 1 < code.length && code[start] == '\r' && code[start + 1] == '\n')
						start += 2;
					else
						start++;
					// support /+ dub.sdl: lines or similar starts directly after a script line
					auto leading = code[start .. $].stripLeft;
					if (leading.startsWith("/+", "/*"))
					{
						size_t end = code.indexOf(leading[1] == '+' ? "+/" : "*/", start);
						if (end != -1)
						{
							start = end + 2;
							if (code[start .. $].startsWith("\r\n"))
								start += 2;
							else if (code[start .. $].startsWith("\r", "\n"))
								start += 1;
						}
					}
				}
			}
			ret.outerFrom = ret.outerTo = ret.from = ret.to = start;
			return ret;
		}

		const(string)[] raw;
		string moduleName;
		foreach (t; tokens[start + 1 .. $])
		{
			if (t.type == tok!";")
			{
				outerTo = t.index + 1;
				break;
			}
			if (t.type == tok!"identifier")
			{
				if (from == 0)
					from = t.index;
				moduleName ~= t.text;
				to = t.index + t.text.length;
				raw ~= t.text;
			}
			if (t.type == tok!".")
			{
				moduleName ~= ".";
			}
		}
		return FileModuleInfo(raw, moduleName, from, to, outerFrom, outerTo);
	}

private:
	LexerConfig config;
}

/// Represents a module statement in a file.
struct FileModuleInfo
{
	/// Parts of the module name as array.
	const(string)[] raw;
	/// Whole modulename as normalized string in form a.b.c etc.
	string moduleName = "";
	/// Code index of the moduleName
	size_t from, to;
	/// Code index of the whole module statement starting right at module and ending right after the semicolon.
	size_t outerFrom, outerTo;

	string toString() const
	{
		return format!"FileModuleInfo[%s..%s](name[%s..%s]=%s)"(outerFrom, outerTo, from, to, moduleName);
	}
}

private:

class ModuleChangerVisitor : ASTVisitor
{
	this(string file, string[] from, string[] to, bool renameSubmodules)
	{
		changes.file = file;
		this.from = from;
		this.to = to;
		this.renameSubmodules = renameSubmodules;
	}

	alias visit = ASTVisitor.visit;

	override void visit(const ModuleDeclaration decl)
	{
		auto mod = decl.moduleName.identifiers.map!(a => a.text).array;
		auto orig = mod;
		if (mod.startsWith(from) && renameSubmodules)
			mod = to ~ mod[from.length .. $];
		else if (mod == from)
			mod = to;
		if (mod != orig)
		{
			foundModule = true;
			changes.replacements ~= CodeReplacement([
					decl.moduleName.identifiers[0].index,
					decl.moduleName.identifiers[$ - 1].index + decl.moduleName.identifiers[$ - 1].text.length
					], mod.join('.'));
		}
	}

	override void visit(const SingleImport imp)
	{
		auto mod = imp.identifierChain.identifiers.map!(a => a.text).array;
		auto orig = mod;
		if (mod.startsWith(from) && renameSubmodules)
			mod = to ~ mod[from.length .. $];
		else if (mod == from)
			mod = to;
		if (mod != orig)
		{
			changes.replacements ~= CodeReplacement([
					imp.identifierChain.identifiers[0].index,
					imp.identifierChain.identifiers[$ - 1].index
					+ imp.identifierChain.identifiers[$ - 1].text.length
					], mod.join('.'));
		}
	}

	override void visit(const ImportDeclaration decl)
	{
		if (decl)
		{
			return decl.accept(this);
		}
	}

	override void visit(const BlockStatement content)
	{
		if (content)
		{
			return content.accept(this);
		}
	}

	string[] from, to;
	FileChanges changes;
	bool renameSubmodules, foundModule;
}

/+
unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	workspace.createDir("source/newmod");
	workspace.createDir("unregistered/source");
	workspace.writeFile("source/newmod/color.d", "module oldmod.color;void foo(){}");
	workspace.writeFile("source/newmod/render.d", "module oldmod.render;import std.color,oldmod.color;import oldmod.color.oldmod:a=b, c;import a=oldmod.a;void bar(){}");
	workspace.writeFile("source/newmod/display.d", "module newmod.displaf;");
	workspace.writeFile("source/newmod/input.d", "");
	workspace.writeFile("source/newmod/package.d", "");
	workspace.writeFile("unregistered/source/package.d", "");
	workspace.writeFile("unregistered/source/app.d", "");
	auto instance = backend.addInstance(workspace.directory);
	backend.register!ModulemanComponent;
	auto mod = backend.get!ModulemanComponent(workspace.directory);

	instance.importPathProvider = () => ["source", "source/deeply/nested/source"];

	FileChanges[] changes = mod.rename("oldmod", "newmod").sort!"a.file < b.file".array;

	assert(changes.length == 2);
	assert(changes[0].file.endsWith("color.d"));
	assert(changes[1].file.endsWith("render.d"));

	assert(changes[0].replacements == [CodeReplacement([7, 19], "newmod.color")]);
	assert(changes[1].replacements == [
			CodeReplacement([7, 20], "newmod.render"),
			CodeReplacement([38, 50], "newmod.color"),
			CodeReplacement([58, 77], "newmod.color.oldmod"),
			CodeReplacement([94, 102], "newmod.a")
			]);

	foreach (change; changes)
	{
		string code = readText(change.file);
		foreach_reverse (op; change.replacements)
			code = op.apply(code);
		std.file.write(change.file, code);
	}

	auto nrm = mod.normalizeModules(workspace.getPath("source/newmod/input.d"), "");
	assert(nrm == [CodeReplacement([0, 0], "module newmod.input;\n\n")]);

	nrm = mod.normalizeModules(workspace.getPath("source/newmod/package.d"), "");
	assert(nrm == [CodeReplacement([0, 0], "module newmod;\n\n")]);

	nrm = mod.normalizeModules(workspace.getPath("source/newmod/display.d"),
			"module oldmod.displaf;");
	assert(nrm == [CodeReplacement([0, 22], "module newmod.display;")]);

	nrm = mod.normalizeModules(workspace.getPath("unregistered/source/app.d"), "");
	assert(nrm == [CodeReplacement([0, 0], "module app;\n\n")]);

	nrm = mod.normalizeModules(workspace.getPath("unregistered/source/package.d"), "");
	assert(nrm == []);

	nrm = mod.normalizeModules(workspace.getPath("source/deeply/nested/source/pkg/test.d"), "");
	assert(nrm == [CodeReplacement([0, 0], "module pkg.test;\n\n")]);

	auto fetched = mod.describeModule("/* hello world */ module\nfoo . \nbar  ;\n\nvoid foo() {");
	assert(fetched == FileModuleInfo(["foo", "bar"], "foo.bar", 25, 35, 18, 38));

	fetched = mod.describeModule(`#!/usr/bin/env dub
/+ dub.sdl:
	name "hello"
+/
void main() {}`);
	assert(fetched == FileModuleInfo([], "", 48, 48, 48, 48));

	fetched = mod.describeModule("#!/usr/bin/rdmd\r\n");
	assert(fetched == FileModuleInfo([], "", 17, 17, 17, 17));

	fetched = mod.describeModule("#!/usr/bin/rdmd\n");
	assert(fetched == FileModuleInfo([], "", 16, 16, 16, 16));
}
+/
