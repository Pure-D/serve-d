/// Component for adding imports to a file, reading imports at a location of code and sorting imports.
module workspaced.com.importer;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import std.algorithm;
import std.array;
import std.functional;
import std.stdio;
import std.string;
import std.uni : sicmp;

import workspaced.api;
import workspaced.helpers : determineIndentation, endsWithKeyword,
	indexOfKeyword, stripLineEndingLength;

/// ditto
@component("importer")
class ImporterComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		config.stringBehavior = StringBehavior.source;
	}

	/// Returns all imports available at some code position.
	ImportInfo[] get(scope const(char)[] code, int pos)
	{
		RollbackAllocator rba;
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto mod = parseModule(tokens, "code", &rba);
		auto reader = new ImporterReaderVisitor(pos);
		reader.visit(mod);
		return reader.imports;
	}

	/// Returns a list of code patches for adding an import.
	/// If `insertOutermost` is false, the import will get added to the innermost block.
	ImportModification add(string importName, scope const(char)[] code, int pos,
			bool insertOutermost = true)
	{
		RollbackAllocator rba;
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto mod = parseModule(tokens, "code", &rba);
		auto reader = new ImporterReaderVisitor(pos);
		reader.visit(mod);
		foreach (i; reader.imports)
		{
			if (i.name.join('.') == importName)
			{
				if (i.selectives.length == 0)
					return ImportModification(i.rename, []);
				else
					insertOutermost = false;
			}
		}
		string indentation = "";
		if (insertOutermost)
		{
			indentation = reader.outerImportLocation == 0 ? "" : (cast(ubyte[]) code)
				.getIndentation(reader.outerImportLocation);
			if (reader.isModule)
				indentation = '\n' ~ indentation;
			return ImportModification("", [
					CodeReplacement([
							reader.outerImportLocation, reader.outerImportLocation
						], indentation ~ "import " ~ importName ~ ";" ~ (reader.outerImportLocation == 0
						? "\n" : ""))
					]);
		}
		else
		{
			indentation = (cast(ubyte[]) code).getIndentation(reader.innermostBlockStart);
			if (reader.isModule)
				indentation = '\n' ~ indentation;
			return ImportModification("", [
					CodeReplacement([
							reader.innermostBlockStart, reader.innermostBlockStart
						], indentation ~ "import " ~ importName ~ ";")
					]);
		}
	}

	/// Sorts the imports in a whitespace separated group of code
	/// Returns `ImportBlock.init` if no changes would be done.
	ImportBlock sortImports(scope const(char)[] code, int pos)
	{
		bool startBlock = true;
		string indentation;
		size_t start, end;
		// find block of code separated by empty lines
		foreach (line; code.lineSplitter!(KeepTerminator.yes))
		{
			if (startBlock)
				start = end;
			startBlock = line.strip.length == 0;
			if (startBlock && end >= pos)
				break;
			end += line.length;
		}
		if (start >= end || end > code.length)
			return ImportBlock.init;
		auto part = code[start .. end];

		// then filter out the proper indentation
		bool inCorrectIndentationBlock;
		size_t acc;
		bool midImport;
		foreach (line; part.lineSplitter!(KeepTerminator.yes))
		{
			const indent = line.determineIndentation;
			bool marksNewRegion;
			bool leavingMidImport;

			auto importStart = line.indexOfKeyword("import");
			const importEnd = line.indexOf(';');
			if (importStart != -1)
			{
				while (true)
				{
					auto rest = line[0 .. importStart].stripRight;
					if (!rest.endsWithKeyword("public") && !rest.endsWithKeyword("static"))
						break;

					// both public and static end with c, so search for c
					// do this to remove whitespaces
					importStart = line[0 .. importStart].lastIndexOf('c');
					// both public and static have same length so subtract by "publi".length (without c)
					importStart -= 5;
				}

				acc += importStart;
				line = line[importStart .. $];

				if (importEnd == -1)
					midImport = true;
				else
					midImport = importEnd < importStart;
			}
			else if (importEnd != -1 && midImport)
				leavingMidImport = true;
			else if (!midImport)
			{
				// got no "import" and wasn't in an import here
				marksNewRegion = true;
			}

			if ((marksNewRegion || indent != indentation) && !midImport)
			{
				if (inCorrectIndentationBlock)
				{
					end = start + acc - line.stripLineEndingLength;
					break;
				}
				start += acc;
				acc = 0;
				indentation = indent;
			}

			if (leavingMidImport)
				midImport = false;

			if (start + acc <= pos && start + acc + line.length - 1 >= pos)
				inCorrectIndentationBlock = true;
			acc += line.length;
		}

		// go back to start of line
		start = code[0 .. start].lastIndexOf('\n', start) + 1;

		part = code[start .. end];

		RollbackAllocator rba;
		auto tokens = getTokensForParser(cast(ubyte[]) part, config, &workspaced.stringCache);
		auto mod = parseModule(tokens, "code", &rba);
		auto reader = new ImporterReaderVisitor(-1);
		reader.visit(mod);

		auto imports = reader.imports;
		if (!imports.length)
			return ImportBlock.init;

		foreach (ref imp; imports)
			imp.start += start;

		start = imports.front.start;
		end = code.indexOf(';', imports.back.start) + 1;

		auto sorted = imports.map!(a => ImportInfo(a.name, a.rename,
				a.selectives.dup.sort!((c, d) => sicmp(c.effectiveName,
				d.effectiveName) < 0).array, a.isPublic, a.isStatic, a.start)).array;
		sorted.sort!((a, b) => ImportInfo.cmp(a, b) < 0);
		if (sorted == imports)
			return ImportBlock.init;
		return ImportBlock(cast(int) start, cast(int) end, sorted, indentation);
	}

private:
	LexerConfig config;
}

/+
unittest
{
	import std.conv : to;

	void assertEqual(ImportBlock a, ImportBlock b)
	{
		assert(a.sameEffectAs(b), a.to!string ~ " is not equal to " ~ b.to!string);
	}

	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!ImporterComponent;

	string code = `import std.stdio;
import std.algorithm;
import std.array;
import std.experimental.logger;
import std.regex;
import std.functional;
import std.file;
import std.path;

import core.thread;
import core.sync.mutex;

import gtk.HBox, gtk.VBox, gtk.MainWindow, gtk.Widget, gtk.Button, gtk.Frame,
	gtk.ButtonBox, gtk.Notebook, gtk.CssProvider, gtk.StyleContext, gtk.Main,
	gdk.Screen, gtk.CheckButton, gtk.MessageDialog, gtk.Window, gtkc.gtk,
	gtk.Label, gdk.Event;

import already;
import sorted;

import std.stdio : writeln, File, stdout, err = stderr;

version(unittest)
	import std.traits;
import std.stdio;
import std.algorithm;

void main()
{
	import std.stdio;
	import std.algorithm;

	writeln("foo");
}

void main()
{
	import std.stdio;
	import std.algorithm;
}

void main()
{
	import std.stdio;
	import std.algorithm;
	string midImport;
	import std.string;
	import std.array;
}

import workspaced.api;
import workspaced.helpers : determineIndentation, stripLineEndingLength, indexOfKeyword;

public import std.string;
public import std.stdio;
import std.traits;
import std.algorithm;
`;

	//dfmt off
	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 0), ImportBlock(0, 164, [
		ImportInfo(["std", "algorithm"]),
		ImportInfo(["std", "array"]),
		ImportInfo(["std", "experimental", "logger"]),
		ImportInfo(["std", "file"]),
		ImportInfo(["std", "functional"]),
		ImportInfo(["std", "path"]),
		ImportInfo(["std", "regex"]),
		ImportInfo(["std", "stdio"])
	]));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 192), ImportBlock(166, 209, [
		ImportInfo(["core", "sync", "mutex"]),
		ImportInfo(["core", "thread"])
	]));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 238), ImportBlock(211, 457, [
		ImportInfo(["gdk", "Event"]),
		ImportInfo(["gdk", "Screen"]),
		ImportInfo(["gtk", "Button"]),
		ImportInfo(["gtk", "ButtonBox"]),
		ImportInfo(["gtk", "CheckButton"]),
		ImportInfo(["gtk", "CssProvider"]),
		ImportInfo(["gtk", "Frame"]),
		ImportInfo(["gtk", "HBox"]),
		ImportInfo(["gtk", "Label"]),
		ImportInfo(["gtk", "Main"]),
		ImportInfo(["gtk", "MainWindow"]),
		ImportInfo(["gtk", "MessageDialog"]),
		ImportInfo(["gtk", "Notebook"]),
		ImportInfo(["gtk", "StyleContext"]),
		ImportInfo(["gtk", "VBox"]),
		ImportInfo(["gtk", "Widget"]),
		ImportInfo(["gtk", "Window"]),
		ImportInfo(["gtkc", "gtk"])
	]));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 467), ImportBlock.init);

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 546), ImportBlock(491, 546, [
		ImportInfo(["std", "stdio"], "", [
			SelectiveImport("stderr", "err"),
			SelectiveImport("File"),
			SelectiveImport("stdout"),
			SelectiveImport("writeln"),
		])
	]));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 593), ImportBlock(586, 625, [
		ImportInfo(["std", "algorithm"]),
		ImportInfo(["std", "stdio"])
	]));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 650), ImportBlock(642, 682, [
		ImportInfo(["std", "algorithm"]),
		ImportInfo(["std", "stdio"])
	], "\t"));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 730), ImportBlock(719, 759, [
		ImportInfo(["std", "algorithm"]),
		ImportInfo(["std", "stdio"])
	], "\t"));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 850), ImportBlock(839, 876, [
		ImportInfo(["std", "array"]),
		ImportInfo(["std", "string"])
	], "\t"));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 897), ImportBlock(880, 991, [
		ImportInfo(["workspaced", "api"]),
		ImportInfo(["workspaced", "helpers"], "", [
			SelectiveImport("determineIndentation"),
			SelectiveImport("indexOfKeyword"),
			SelectiveImport("stripLineEndingLength")
		])
	]));

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 1010), ImportBlock(993, 1084, [
		ImportInfo(["std", "stdio"], null, null, true),
		ImportInfo(["std", "string"], null, null, true),
		ImportInfo(["std", "algorithm"]),
		ImportInfo(["std", "traits"])
	]));

	// ----------------

	code = `void foo()
{
	// import std.algorithm;
	// import std.array;
	import std.path;
	import std.file;
}`;

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 70), ImportBlock(62, 96, [
		ImportInfo(["std", "file"]),
		ImportInfo(["std", "path"])
	], "\t"));

	code = `void foo()
{
	/*
	import std.algorithm;
	import std.array; */
	import std.path;
	import std.file;
}`;

	assertEqual(backend.get!ImporterComponent(workspace.directory).sortImports(code, 75), ImportBlock(63, 97, [
		ImportInfo(["std", "file"]),
		ImportInfo(["std", "path"])
	], "\t"));
	//dfmt on
}
+/

/// Information about how to add an import
struct ImportModification
{
	/// Set if there was already an import which was renamed. (for example import io = std.stdio; would be "io")
	string rename;
	/// Array of replacements to add the import to the code
	CodeReplacement[] replacements;
}

/// Name and (if specified) rename of a symbol
struct SelectiveImport
{
	/// Original name (always available)
	string name;
	/// Rename if specified
	string rename;

	/// Returns rename if set, otherwise name
	string effectiveName() const
	{
		return rename.length ? rename : name;
	}

	/// Returns a D source code part
	string toString() const
	{
		return (rename.length ? rename ~ " = " : "") ~ name;
	}
}

/// Information about one import statement
struct ImportInfo
{
	/// Parts of the imported module. (std.stdio -> ["std", "stdio"])
	string[] name;
	/// Available if the module has been imported renamed
	string rename;
	/// Array of selective imports or empty if the entire module has been imported
	SelectiveImport[] selectives;
	/// If this is an explicitly `public import` (not checking potential attributes spanning this)
	bool isPublic;
	/// If this is an explicityl `static import` (not checking potential attributes spanning this)
	bool isStatic;
	/// Index where the first token of the import declaration starts, possibly including attributes.
	size_t start;

	/// Returns the rename if available, otherwise the name joined with dots
	string effectiveName() const
	{
		return rename.length ? rename : name.join('.');
	}

	/// Returns D source code for this import
	string toString() const
	{
		import std.conv : to;

		auto ret = appender!string;
		if (isPublic)
			ret.put("public ");
		if (isStatic)
			ret.put("static ");
		ret.put("import ");
		if (rename.length)
			ret.put(rename ~ " = ");
		ret.put(name.join('.'));
		if (selectives.length)
			ret.put(" : " ~ selectives.to!(string[]).join(", "));
		ret.put(';');
		return ret.data;
	}

	/// Returns: true if this ImportInfo is the same as another one except for definition location
	bool sameEffectAs(in ImportInfo other) const
	{
		return name == other.name && rename == other.rename && selectives == other.selectives
			&& isPublic == other.isPublic && isStatic == other.isStatic;
	}

	static int cmp(ImportInfo a, ImportInfo b)
	{
		const ax = (a.isPublic ? 2 : 0) | (a.isStatic ? 1 : 0);
		const bx = (b.isPublic ? 2 : 0) | (b.isStatic ? 1 : 0);
		const x = ax - bx;
		if (x != 0)
			return -x;

		return sicmp(a.effectiveName, b.effectiveName);
	}
}

/// A block of imports generated by the sort-imports command
struct ImportBlock
{
	/// Start & end byte index
	int start, end;
	///
	ImportInfo[] imports;
	///
	string indentation;

	bool sameEffectAs(in ImportBlock other) const
	{
		if (!(start == other.start && end == other.end && indentation == other.indentation))
			return false;

		if (imports.length != other.imports.length)
			return false;

		foreach (i; 0 .. imports.length)
			if (!imports[i].sameEffectAs(other.imports[i]))
				return false;

		return true;
	}
}

private:

string getIndentation(ubyte[] code, size_t index)
{
	import std.ascii : isWhite;

	bool atLineEnd = false;
	if (index < code.length && code[index] == '\n')
	{
		for (size_t i = index; i < code.length; i++)
			if (!code[i].isWhite)
				break;
		atLineEnd = true;
	}
	while (index > 0)
	{
		if (code[index - 1] == cast(ubyte) '\n')
			break;
		index--;
	}
	size_t end = index;
	while (end < code.length)
	{
		if (!code[end].isWhite)
			break;
		end++;
	}
	auto indent = cast(string) code[index .. end];
	if (!indent.length && index == 0 && !atLineEnd)
		return " ";
	return "\n" ~ indent.stripLeft('\n');
}

/*
unittest
{
	auto code = cast(ubyte[]) "void foo() {\n\tfoo();\n}";
	auto indent = getIndentation(code, 20);
	assert(indent == "\n\t", '"' ~ indent ~ '"');

	code = cast(ubyte[]) "void foo() { foo(); }";
	indent = getIndentation(code, 19);
	assert(indent == " ", '"' ~ indent ~ '"');

	code = cast(ubyte[]) "import a;\n\nvoid foo() {\n\tfoo();\n}";
	indent = getIndentation(code, 9);
	assert(indent == "\n", '"' ~ indent ~ '"');
}
*/

class ImporterReaderVisitor : ASTVisitor
{
	this(int pos)
	{
		this.pos = pos;
		inBlock = false;
	}

	alias visit = ASTVisitor.visit;

	override void visit(const ModuleDeclaration decl)
	{
		if (pos != -1 && (decl.endLocation + 1 < outerImportLocation || inBlock))
			return;
		isModule = true;
		outerImportLocation = decl.endLocation + 1;
	}

	override void visit(const ImportDeclaration decl)
	{
		if (pos != -1 && decl.startIndex >= pos)
			return;
		isModule = false;
		if (inBlock)
			innermostBlockStart = decl.endIndex;
		else
			outerImportLocation = decl.endIndex;
		foreach (i; decl.singleImports)
			imports ~= ImportInfo(i.identifierChain.identifiers.map!(tok => tok.text.idup)
					.array, i.rename.text, null, publicStack > 0, staticStack > 0, declStart);
		if (decl.importBindings)
		{
			ImportInfo info;
			if (!decl.importBindings.singleImport)
				return;
			info.name = decl.importBindings.singleImport.identifierChain.identifiers.map!(
					tok => tok.text.idup).array;
			info.rename = decl.importBindings.singleImport.rename.text;
			foreach (bind; decl.importBindings.importBinds)
			{
				if (bind.right.text)
					info.selectives ~= SelectiveImport(bind.right.text, bind.left.text);
				else
					info.selectives ~= SelectiveImport(bind.left.text);
			}
			info.start = declStart;
			info.isPublic = publicStack > 0;
			info.isStatic = staticStack > 0;
			if (info.selectives.length)
				imports ~= info;
		}
	}

	override void visit(const Declaration decl)
	{
		if (decl)
		{
			bool hasPublic, hasStatic;
			foreach (attr; decl.attributes)
			{
				if (attr.attribute == tok!"public")
					hasPublic = true;
				else if (attr.attribute == tok!"static")
					hasStatic = true;
			}
			if (hasPublic)
				publicStack++;
			if (hasStatic)
				staticStack++;
			declStart = decl.tokens[0].index;

			scope (exit)
			{
				if (hasStatic)
					staticStack--;
				if (hasPublic)
					publicStack--;
				declStart = -1;
			}
			return decl.accept(this);
		}
	}

	override void visit(const BlockStatement content)
	{
		if (pos == -1 || (content && pos >= content.startLocation && pos < content.endLocation))
		{
			if (content.startLocation + 1 >= innermostBlockStart)
				innermostBlockStart = content.startLocation + 1;
			inBlock = true;
			return content.accept(this);
		}
	}

	private int pos;
	private bool inBlock;
	private int publicStack, staticStack;
	private size_t declStart;

	ImportInfo[] imports;
	bool isModule;
	size_t outerImportLocation;
	size_t innermostBlockStart;
}

/*
unittest
{
	import std.conv;

	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!ImporterComponent;
	auto imports = backend.get!ImporterComponent(workspace.directory).get("import std.stdio; void foo() { import fs = std.file; import std.algorithm : map, each2 = each; writeln(\"hi\"); } void bar() { import std.string; import std.regex : ctRegex; }",
			81);
	bool equalsImport(ImportInfo i, string s)
	{
		return i.name.join('.') == s;
	}

	void assertEquals(T)(T a, T b)
	{
		assert(a == b, "'" ~ a.to!string ~ "' != '" ~ b.to!string ~ "'");
	}

	assertEquals(imports.length, 3);
	assert(equalsImport(imports[0], "std.stdio"));
	assert(equalsImport(imports[1], "std.file"));
	assertEquals(imports[1].rename, "fs");
	assert(equalsImport(imports[2], "std.algorithm"));
	assertEquals(imports[2].selectives.length, 2);
	assertEquals(imports[2].selectives[0].name, "map");
	assertEquals(imports[2].selectives[1].name, "each");
	assertEquals(imports[2].selectives[1].rename, "each2");

	string code = "void foo() { import std.stdio : stderr; writeln(\"hi\"); }";
	auto mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"void foo() { import std.stdio : stderr; import std.stdio; writeln(\"hi\"); }");

	code = "void foo() {\n\timport std.stdio : stderr;\n\twriteln(\"hi\");\n}";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"void foo() {\n\timport std.stdio : stderr;\n\timport std.stdio;\n\twriteln(\"hi\");\n}");

	code = "void foo() {\n\timport std.file : readText;\n\twriteln(\"hi\");\n}";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"import std.stdio;\nvoid foo() {\n\timport std.file : readText;\n\twriteln(\"hi\");\n}");

	code = "void foo() { import io = std.stdio; io.writeln(\"hi\"); }";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 45);
	assertEquals(mod.rename, "io");
	assertEquals(mod.replacements.length, 0);

	code = "import std.file : readText;\n\nvoid foo() {\n\twriteln(\"hi\");\n}";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 45);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"import std.file : readText;\nimport std.stdio;\n\nvoid foo() {\n\twriteln(\"hi\");\n}");

	code = "import std.file;\nimport std.regex;\n\nvoid foo() {\n\twriteln(\"hi\");\n}";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 54);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"import std.file;\nimport std.regex;\nimport std.stdio;\n\nvoid foo() {\n\twriteln(\"hi\");\n}");

	code = "module a;\n\nvoid foo() {\n\twriteln(\"hi\");\n}";
	mod = backend.get!ImporterComponent(workspace.directory).add("std.stdio", code, 30);
	assertEquals(mod.rename, "");
	assertEquals(mod.replacements.length, 1);
	assertEquals(mod.replacements[0].apply(code),
			"module a;\n\nimport std.stdio;\n\nvoid foo() {\n\twriteln(\"hi\");\n}");
}
*/
