import std.conv;
import std.algorithm;
import pegged.grammar;

static import pegged.peg;

///
enum CompletionType : ubyte
{
	///
	Undefined = 0,
	///
	Class = 1,
	///
	String = 2,
	///
	Number = 3,
	///
	Color = 4,
	///
	EnumDefinition = 5,
	///
	EnumValue = 6,
	///
	Rectangle = 7,
	///
	Boolean = 8,
}

struct CompletionLookup
{
	CompletionItem item;
	string[][] providedScope = [];
	string[] requiredScope = [];
}

/// quote string: append double quotes, screen all special chars;
/// so quoted string forms valid D string literal.
/// allocates.
string quote(const(char)[] s)
{
	import std.array : appender;
	import std.format : formatElement, FormatSpec;

	auto res = appender!string();
	FormatSpec!char fspc; // defaults to 's'
	formatElement(res, s, fspc);
	return res.data;
}

struct CompletionItem
{
	CompletionType type;
	string value;
	string documentation = "";
	string enumName = "";

	string toString()
	{
		return "CompletionItem(CompletionType." ~ type.to!string ~ ", "
			~ value.quote ~ ", " ~ documentation.quote ~ ", " ~ enumName.quote ~ ")";
	}
}

mixin(grammar(`
DML:
	Content < ( EnumBlock / ClassBlock )*
	Documentation <- :"---" :Spacing? ~(!endOfLine .)* :endOfLine
	EnumBlock < "enum" :Spacing identifier Documentation? :'{' EnumMember* :'}'
	EnumDefinition < identifier
	ClassBlock < "class" :Spacing identifier Documentation? :'{' ClassMember* :'}'
	ClassMember < "include" :Spacing identifier :';'
	            / identifier :Spacing identifier :';' Documentation?
	EnumMember < identifier :';' Documentation?
	Comment <: "//" (!endOfLine .)* endOfLine
	Spacing <~ (space / endOfLine / Comment)*
`));

struct ClassDependency
{
	CompletionLookup type;
	CompletionLookup[] members;
	string[] remainingDependencies;
}

CompletionLookup[] generateCompletions(string completionLookup)
{
	if (__ctfe)
	{
		assert(0);
	}
	CompletionLookup[] enumCompletions;
	CompletionLookup[] classCompletions;
	ParseTree tree = DML(completionLookup);
	assert(tree.successful);
	assert(tree.children.length == 1);
	assert(tree.children[0].name == "DML.Content");
	ParseTree content = tree.children[0];
	ClassDependency[] dependTree;
	string[] classes;
	string[] enums;

	foreach (child; content.children)
	{
		if (child.name == "DML.EnumBlock")
		{
			enums ~= child.matches[1];
			foreach (val; child.children)
			{
				/// TODO: Add enum type itself
				if (val.name == "DML.EnumMember")
				{
					string documentation = "";
					if (val.children.length > 0 && val.children[0].name == "DML.Documentation")
						documentation = val.children[0].matches[0];
					enumCompletions ~= CompletionLookup(CompletionItem(CompletionType.EnumDefinition,
							val.matches[0], documentation, child.matches[1]), [], []);
				}
			}
		}
		else if (child.name == "DML.ClassBlock")
			classes ~= child.matches[1];
		else
			assert(0);
	}

	foreach (child; content.children)
	{
		if (child.name == "DML.ClassBlock")
		{
			CompletionLookup[] members;
			string[] dependencies;
			foreach (member; child.children)
			{
				if (member.name == "DML.ClassMember")
				{
					string documentation = "";
					if (member.children.length > 0 && member.children[0].name == "DML.Documentation")
						documentation = member.children[0].matches[0];
					string type = member.matches[0];
					string name = member.matches[1];
					if (type == "include")
						dependencies ~= name;
					else if (type == "bool")
						members ~= CompletionLookup(CompletionItem(CompletionType.Boolean,
								name, documentation), [], [child.matches[1]]);
					else if (type == "color")
						members ~= CompletionLookup(CompletionItem(CompletionType.Color,
								name, documentation), [], [child.matches[1]]);
					else if (type == "number")
						members ~= CompletionLookup(CompletionItem(CompletionType.Number,
								name, documentation), [], [child.matches[1]]);
					else if (type == "rect")
						members ~= CompletionLookup(CompletionItem(CompletionType.Rectangle,
								name, documentation), [], [child.matches[1]]);
					else if (type == "string")
						members ~= CompletionLookup(CompletionItem(CompletionType.String,
								name, documentation), [], [child.matches[1]]);
					else
					{
						assert(!classes.canFind(type), "Member values can not be of type class!");
						assert(enums.canFind(type), "Undefined value type '" ~ type ~ "'");
						members ~= CompletionLookup(CompletionItem(CompletionType.EnumValue,
								name, documentation, type), [], [child.matches[1]]);
					}
				}
			}
			string[][] scopes;
			foreach (dep; dependencies)
			{
				if (!classes.canFind(dep))
					assert(0, "Can't find class to include: " ~ dep);
				scopes ~= [dep];
			}
			scopes ~= [child.matches[1]];
			string documentation = "";
			if (child.children.length > 0 && child.children[0].name == "DML.Documentation")
				documentation = child.children[0].matches[0];
			CompletionLookup type = CompletionLookup(CompletionItem(CompletionType.Class,
					child.matches[1], documentation), scopes, []);
			dependTree ~= ClassDependency(type, members, dependencies);
		}
	}

	int i = 0;
	while (true)
	{
		if (i++ > 50)
			throw new Exception("Circular include");
		bool done = true;
		foreach (ref dep; dependTree)
		{
			DepLoop: foreach_reverse (n, remaining; dep.remainingDependencies)
			{
				done = false;
				foreach (loaded; dependTree)
				{
					if (loaded.type.item.value == remaining
							&& loaded.remainingDependencies.length == 0)
					{
						dep.type.providedScope ~= loaded.type.providedScope;
						string[][] newProvidedScope;
						foreach (sc; dep.type.providedScope)
							if (!newProvidedScope.canFind(sc))
								newProvidedScope ~= sc;
						dep.type.providedScope = newProvidedScope;
						dep.remainingDependencies = dep.remainingDependencies.remove(n);
						continue DepLoop;
					}
				}
			}
		}
		if (done)
			break;
	}

	foreach (dep; dependTree)
		classCompletions ~= dep.type ~ dep.members;

	return enumCompletions ~ classCompletions;
}

void test()
{
	import dunit.toolkit;

	string testCode = q{
		enum Test --- description 1
		{
			A; --- A=2
			B; --- B=3
			C;
			D; --- D=5
		}
		class Something --- description 2
		{
			Test test; --- will do something
			number foo; --- bar
			string bar; --- foo
			bool test; --- no comment
			rect abc;
		}
		class Else
		{
			number def; --- extended
			include Something;
		}
	};
	auto completions = generateCompletions(testCode);

	//dfmt off
	assertEqual(completions, [
		CompletionLookup(CompletionItem(CompletionType.EnumDefinition, "A", "A=2", "Test")),
		CompletionLookup(CompletionItem(CompletionType.EnumDefinition, "B", "B=3", "Test")),
		CompletionLookup(CompletionItem(CompletionType.EnumDefinition, "C", "", "Test")),
		CompletionLookup(CompletionItem(CompletionType.EnumDefinition, "D", "D=5", "Test")),
		CompletionLookup(CompletionItem(CompletionType.Class, "Something", "description 2"), [["Something"]], []),
		CompletionLookup(CompletionItem(CompletionType.EnumValue, "test", "will do something", "Test"), [], ["Something"]),
		CompletionLookup(CompletionItem(CompletionType.Number, "foo", "bar"), [], ["Something"]),
		CompletionLookup(CompletionItem(CompletionType.String, "bar", "foo"), [], ["Something"]),
		CompletionLookup(CompletionItem(CompletionType.Boolean, "test", "no comment"), [], ["Something"]),
		CompletionLookup(CompletionItem(CompletionType.Rectangle, "abc", ""), [], ["Something"]),
		CompletionLookup(CompletionItem(CompletionType.Class, "Else", ""), [["Something"], ["Else"]], []),
		CompletionLookup(CompletionItem(CompletionType.Number, "def", "extended"), [], ["Else"]),
	]);
	//dfmt on
}
