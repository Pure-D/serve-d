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
@globalOnly
class ImporterComponent : ComponentWrapper
{
	mixin DefaultGlobalComponentWrapper;

	protected void load()
	{
		config.stringBehavior = StringBehavior.source;
	}

	/// Returns all imports available at some code position.
	ScopeImportInfo get(scope const(char)[] code, int pos)
	{
		RollbackAllocator rba;
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto mod = parseModule(tokens, "code", &rba);
		auto reader = new ImporterReaderVisitor(pos);
		reader.visit(mod);
		return ScopeImportInfo(reader.thisModule, reader.imports);
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
	///
	/// Params:
	///   code = UTF-8 encoded code text
	///   pos = byte offset where to sort
	///   organizeSelective = true to merge same import names and deduplicate symbols.
	ImportBlock sortImports(scope const(char)[] code, int pos, bool organizeSelective = false)
	{
		foreach (block; findImportCodeSlices(code))
			if (block.contains(pos))
				return sortImportBlock(code, block, organizeSelective);
		return ImportBlock.init;
	}

	/// ditto
	ImportBlock sortImportBlock(scope const(char)[] code, ImportCodeSlice target, bool organizeSelective = false)
	{
		// go back to start of line
		target.start = cast(int)(code[0 .. target.start].lastIndexOf('\n', target.start) + 1);

		auto part = code[target.start .. target.end];
		auto indentation = part.getLineStartIndent.idup;

		RollbackAllocator rba;
		auto tokens = getTokensForParser(cast(ubyte[]) part, config, &workspaced.stringCache);
		auto mod = parseModule(tokens, "code", &rba);
		auto reader = new ImporterReaderVisitor(-1);
		reader.visit(mod);

		auto imports = reader.imports;
		if (!imports.length)
			return ImportBlock.init;

		foreach (ref imp; imports)
			imp.start += target.start;

		target.start = cast(int)imports.front.start;
		target.end = cast(int) code.indexOf(';', imports.back.start) + 1;

		auto sorted = imports.map!(a => ImportInfo(a.name, a.rename,
				a.selectives.dup.sort!((c, d) => sicmp(c.effectiveName,
				d.effectiveName) < 0).release, a.isPublic, a.isStatic, a.start))
			.array
			.sort!((a, b) => ImportInfo.cmp(a, b) < 0)
			.release;
		if (organizeSelective)
			this.organizeSelective(sorted);
		if (sorted == imports)
			return ImportBlock.init;
		return ImportBlock(target.start, target.end, sorted, indentation.idup);
	}

	/// Merges duplicate imports into single ones, removes duplicate selective
	/// import symbols.
	void organizeSelective(ref ImportInfo[] imports)
	{
		if (!imports.length)
			return;
		for (size_t i = imports.length - 1; i >= 1; i--)
		{
			auto before = &imports[i - 1];
			auto imp = &imports[i];

			if (before.name == imp.name
				&& before.isPublic == imp.isPublic
				&& before.isStatic == imp.isStatic
				&& before.rename == imp.rename)
			{
				if (before.selectives.length > 0 && imp.selectives.length > 0)
				{
					// import foo : bar; import foo : baz;
					// -> import foo : bar, baz;
					before.selectives ~= imp.selectives;
					before.selectives.sort!((c, d) => sicmp(c.effectiveName,
							d.effectiveName) < 0);
					imports = imports.remove(i);
				}
				else if (!before.selectives.length && !imp.selectives.length)
				{
					// import foo; import foo;
					// -> import foo;
					imports = imports.remove(i);
				}
				// else == `import foo; import foo : bar;` - keep as is
			}
		}

		foreach (ref imp; imports)
		{
			auto deduped = imp.selectives.uniq;
			if (count(deduped) != imp.selectives.length)
				imp.selectives = deduped.array;
		}
	}

	ImportCodeSlice[] findImportCodeSlices(scope const(char)[] code)
	{
		auto ret = appender!(ImportCodeSlice[]);

		LexerConfig config;
		config.stringBehavior = StringBehavior.source;
		config.whitespaceBehavior = WhitespaceBehavior.skip;
		config.commentBehavior = CommentBehavior.noIntern;

		bool inImport;

		int expectedLine;
		size_t protectionIndex = -1;
		size_t protectionIndent = -1;

		ImportCodeSlice current;
		bool changeLast;

		void submitBlock()
		{
			if (current != ImportCodeSlice.init)
			{
				if (changeLast)
					ret.data[$ - 1] = current;
				else
					ret ~= current;
			}
			changeLast = false;
			current = ImportCodeSlice.init;
		}

		void resumeBlock()
		{
			current = ret.data[$ - 1];
			changeLast = true;
		}

		auto lexer = DLexer(code, config, &workspaced.stringCache);
		Token lastToken;
		loop: foreach (token; lexer)
		{
			scope (exit)
				lastToken = token;
			switch (token.type)
			{
			case tok!"whitespace":
			case tok!"specialTokenSequence":
			case tok!"comment":
				break;
			case tok!"__EOF__":
				break loop;
			case tok!"import":
				int indent;
				if (protectionIndent != -1)
					indent = cast(int)protectionIndent - 1;
				else
					indent = cast(int)token.column - 1;
				if (cast(int)token.line <= expectedLine
					&& ret.data.length
					&& ret.data[$ - 1].column == indent)
				{
					resumeBlock();
				}
				else
				{
					current.column = indent;
					current.start = cast(int)token.index;
					if (protectionIndent != -1) // use indent also to check if index is set
						current.start = cast(int)protectionIndex;
				}
				inImport = true;
				expectedLine = cast(int)token.line + 1;
				break;
			case tok!"public":
			case tok!"package":
			case tok!"private":
				protectionIndex = token.index;
				protectionIndent = token.column;
				break;
			case tok!")":
			case tok!".":
			case tok!",":
			case tok!":":
			case tok!"=":
				break;
			case tok!"identifier":
				if (lastToken == tok!"identifier")
					goto invalidImport;
				break;
			case tok!"(":
				// ok for `package(foo)`
				// not ok for `import("foo")`
				if (inImport)
					goto invalidImport;
				break;
			case tok!";":
				if (inImport)
				{
					current.end = cast(int)token.index + 1;
					inImport = false;
					protectionIndent = -1;
					submitBlock();
				}
				break;
			default:
			invalidImport:
				expectedLine = -1;
				protectionIndent = -1;
				inImport = false;
				submitBlock();
				break;
			}
		}
		submitBlock();

		return ret.data;
	}

private:
	LexerConfig config;
}

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
	auto importer = instance.get!ImporterComponent;

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
`.normLF;

	assert(backend.get!ImporterComponent.findImportCodeSlices(code) == [
		ImportCodeSlice(0, 164),
		ImportCodeSlice(166, 209),
		ImportCodeSlice(211, 457),
		ImportCodeSlice(459, 489),
		ImportCodeSlice(491, 546),
		ImportCodeSlice(567, 585, 1),
		ImportCodeSlice(586, 625),
		ImportCodeSlice(642, 682, 1),
		ImportCodeSlice(719, 759, 1),
		ImportCodeSlice(778, 818, 1),
		ImportCodeSlice(839, 876, 1),
		ImportCodeSlice(880, 991),
		ImportCodeSlice(993, 1084),
	]);

	//dfmt off
	assertEqual(importer.sortImports(code, 0), ImportBlock(0, 164, [
		ImportInfo(["std", "algorithm"]),
		ImportInfo(["std", "array"]),
		ImportInfo(["std", "experimental", "logger"]),
		ImportInfo(["std", "file"]),
		ImportInfo(["std", "functional"]),
		ImportInfo(["std", "path"]),
		ImportInfo(["std", "regex"]),
		ImportInfo(["std", "stdio"])
	]));

	assertEqual(importer.sortImports(code, 192), ImportBlock(166, 209, [
		ImportInfo(["core", "sync", "mutex"]),
		ImportInfo(["core", "thread"])
	]));

	assertEqual(importer.sortImports(code, 238), ImportBlock(211, 457, [
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

	assertEqual(importer.sortImports(code, 467), ImportBlock.init);

	assertEqual(importer.sortImports(code, 546), ImportBlock(491, 546, [
		ImportInfo(["std", "stdio"], "", [
			SelectiveImport("stderr", "err"),
			SelectiveImport("File"),
			SelectiveImport("stdout"),
			SelectiveImport("writeln"),
		])
	]));

	assertEqual(importer.sortImports(code, 593), ImportBlock(586, 625, [
		ImportInfo(["std", "algorithm"]),
		ImportInfo(["std", "stdio"])
	]));

	assertEqual(importer.sortImports(code, 650), ImportBlock(642, 682, [
		ImportInfo(["std", "algorithm"]),
		ImportInfo(["std", "stdio"])
	], "\t"));

	assertEqual(importer.sortImports(code, 730), ImportBlock(719, 759, [
		ImportInfo(["std", "algorithm"]),
		ImportInfo(["std", "stdio"])
	], "\t"));

	assertEqual(importer.sortImports(code, 850), ImportBlock(839, 876, [
		ImportInfo(["std", "array"]),
		ImportInfo(["std", "string"])
	], "\t"));

	assertEqual(importer.sortImports(code, 897), ImportBlock(880, 991, [
		ImportInfo(["workspaced", "api"]),
		ImportInfo(["workspaced", "helpers"], "", [
			SelectiveImport("determineIndentation"),
			SelectiveImport("indexOfKeyword"),
			SelectiveImport("stripLineEndingLength")
		])
	]));

	assertEqual(importer.sortImports(code, 1010), ImportBlock(993, 1084, [
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
}`.normLF;

	assertEqual(importer.sortImports(code, 70), ImportBlock(62, 96, [
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
}`.normLF;

	assertEqual(importer.sortImports(code, 75), ImportBlock(63, 97, [
		ImportInfo(["std", "file"]),
		ImportInfo(["std", "path"])
	], "\t"));

	code = `void foo()
{
	import std.file : foo;
	import std.path;
	import std.file;
	import std.file : bar;
	import std.math : min;
	import std.path;
	import std.math : max;
}`.normLF;

	assertEqual(importer.sortImports(code, 25, true), ImportBlock(14, 162, [
		ImportInfo(["std", "file"]),
		ImportInfo(["std", "file"], "", [
			SelectiveImport("bar"),
			SelectiveImport("foo"),
		]),
		ImportInfo(["std", "math"], "", [
			SelectiveImport("max"),
			SelectiveImport("min"),
		]),
		ImportInfo(["std", "path"])
	], "\t"));
	//dfmt on
}

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

		auto ret = sicmp(a.effectiveName, b.effectiveName);
		if (ret != 0)
			return ret;
		if (a.selectives.length && !b.selectives.length)
			return 1;
		if (!a.selectives.length && b.selectives.length)
			return -1;
		return 0;
	}
}

struct ScopeImportInfo
{
	string[] definitonModule;
	ImportInfo[] availableImports;
	alias availableImports this;
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

/// An import slice that groups together (visually) related imports
struct ImportCodeSlice
{
	/// Start & end byte index
	int start, end;
	/// Columnt (indentation) of this import block
	int column;

	/// Returns true if `index` is within this code slice.
	bool contains(int index)
	{
		return index >= start && index <= end;
	}
}

private:

auto getLineStartIndent(scope const(char)[] line)
{
	return line[0 .. $ - line.stripLeft.length];
}

string getIndentation(scope const(ubyte)[] code, size_t index)
{
	import std.ascii : isWhite;
	import std.conv : text;

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
	auto indent = cast(const(char)[])code[index .. end];
	if (!indent.length && index == 0 && !atLineEnd)
		return " ";
	return text("\n", indent.stripLeft('\n'));
}

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
		if (decl.moduleName)
			thisModule = decl.moduleName.identifiers.map!(tok => tok.text.idup).array;
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
	string[] thisModule;
	bool isModule;
	size_t outerImportLocation;
	size_t innermostBlockStart;
}

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
