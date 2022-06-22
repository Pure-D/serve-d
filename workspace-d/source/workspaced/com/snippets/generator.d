module workspaced.com.snippets.generator;

// debug = TraceGenerator;

import dparse.ast;
import dparse.lexer;

import workspaced.api;
import workspaced.com.snippets;
import workspaced.dparseext;

import std.algorithm;
import std.array;
import std.conv;
import std.meta : AliasSeq;

/// Checks if a variable is suitable to be iterated over and finds out information about it
/// Params:
///   ret = loop scope to manipulate
///   variable = variable to check
/// Returns: true if this variable is suitable for iteration, false if not
bool fillLoopScopeInfo(ref SnippetLoopScope ret, const scope VariableUsage variable)
{
	// try to minimize false positives as much as possible here!
	// the first true result will stop the whole loop variable finding process

	if (!variable.name.text.length)
		return false;

	if (variable.type)
	{
		if (variable.type.typeSuffixes.length)
		{
			if (variable.type.typeSuffixes[$ - 1].array)
			{
				const isMap = !!variable.type.typeSuffixes[$ - 1].type;

				ret.stringIterator = variable.type.type2
					&& variable.type.type2.builtinType.among!(tok!"char", tok!"wchar", tok!"dchar");
				ret.type = formatType(variable.type.typeConstructors,
						variable.type.typeSuffixes[0 .. $ - 1], variable.type.type2);
				ret.iterator = variable.name.text;
				ret.numItems = isMap ? 2 : 1;
				return true;
			}
		}
		else if (variable.type.type2 && variable.type.type2.typeIdentifierPart)
		{
			// hardcode string, wstring and dstring
			const t = variable.type.type2.typeIdentifierPart;
			if (!t.dot && !t.indexer && !t.typeIdentifierPart && t.identifierOrTemplateInstance)
			{
				const simpleTypeName = t.identifierOrTemplateInstance.identifier.tokenText;
				switch (simpleTypeName)
				{
				case "string":
				case "wstring":
				case "dstring":
					ret.stringIterator = true;
					ret.iterator = variable.name.text;
					return true;
				default:
					break;
				}
			}
		}
	}

	if (variable.value)
	{
		if (variable.value.arrayInitializer)
		{
			bool isMap;
			auto items = variable.value.arrayInitializer.arrayMemberInitializations;
			if (items.length)
				isMap = !!items[0].assignExpression; // this is the value before the ':' or null for no key

			ret.stringIterator = false;
			ret.iterator = variable.name.text;
			ret.numItems = isMap ? 2 : 1;
			return true;
		}
		else if (variable.value.assignExpression)
		{
			// TODO: determine if this is a loop variable based on value
		}
	}

	return false;
}

string formatType(const IdType[] typeConstructors, const TypeSuffix[] typeSuffixes, const Type2 type2) @trusted
{
	Type t = new Type();
	t.typeConstructors = cast(IdType[]) typeConstructors;
	t.typeSuffixes = cast(TypeSuffix[]) typeSuffixes;
	t.type2 = cast(Type2) type2;
	return astToString(t);
}

/// Helper struct containing variable definitions and notable assignments which 
struct VariableUsage
{
	const Type type;
	const Token name;
	const NonVoidInitializer value;
}

unittest
{
	import std.experimental.logger : globalLogLevel, LogLevel;

	globalLogLevel = LogLevel.trace;

	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!SnippetsComponent;
	SnippetsComponent snippets = backend.get!SnippetsComponent(workspace.directory);

	static immutable loopCode = `module something;

void foo()
{
	int[] x = [1, 2, 3];
	// trivial loop
	
}

void bar()
{
	auto houseNumbers = [1, 2, 3];
	// non-trivial (auto) loop
	
}

void existing()
{
	int[3] items = [1, 2, 3];
	int item;
	// clashing name
	
}

void strings()
{
	string x;
	int y;
	// characters of x
	
}

void noValue()
{
	int hello;
	// no lists
	
}

void map()
{
	auto map = ["hello": "world", "key": "value"];
	// key, value

}`;

	SnippetInfo i;
	SnippetLoopScope s;

	i = snippets.determineSnippetInfo(null, loopCode, 18);
	assert(i.level == SnippetLevel.global);
	s = i.loopScope; // empty
	assert(s == SnippetLoopScope.init);

	i = snippets.determineSnippetInfo(null, loopCode, 30);
	assert(i.level == SnippetLevel.other, i.stack.to!string);
	s = i.loopScope; // empty
	assert(s == SnippetLoopScope.init);

	i = snippets.determineSnippetInfo(null, loopCode, 31);
	assert(i.level == SnippetLevel.method, i.stack.to!string);
	i = snippets.determineSnippetInfo(null, loopCode, 73);
	assert(i.level == SnippetLevel.method, i.stack.to!string);
	i = snippets.determineSnippetInfo(null, loopCode, 74);
	assert(i.level == SnippetLevel.global, i.stack.to!string);

	i = snippets.determineSnippetInfo(null, loopCode, 43);
	assert(i.level == SnippetLevel.value);
	s = i.loopScope; // in value
	assert(s == SnippetLoopScope.init);

	i = snippets.determineSnippetInfo(null, loopCode, 72);
	assert(i.level == SnippetLevel.method);
	s = i.loopScope; // trivial of x
	assert(s.supported);
	assert(!s.stringIterator);
	assert(s.type == "int");
	assert(s.iterator == "x");

	i = snippets.determineSnippetInfo(null, loopCode, 150);
	assert(i.level == SnippetLevel.method);
	s = i.loopScope; // non-trivial of houseNumbers (should be named houseNumber)
	assert(s.supported);
	assert(!s.stringIterator);
	assert(null == s.type);
	assert(s.iterator == "houseNumbers");

	i = snippets.determineSnippetInfo(null, loopCode, 229);
	assert(i.level == SnippetLevel.method);
	s = i.loopScope; // non-trivial of items with existing variable name
	assert(s.supported);
	assert(!s.stringIterator);
	assert(s.type == "int");
	assert(s.iterator == "items");

	i = snippets.determineSnippetInfo(null, loopCode, 290);
	assert(i.level == SnippetLevel.method);
	s = i.loopScope; // string iteration 
	assert(s.supported);
	assert(s.stringIterator);
	assert(null == s.type);
	assert(s.iterator == "x");

	i = snippets.determineSnippetInfo(null, loopCode, 337);
	assert(i.level == SnippetLevel.method);
	s = i.loopScope; // no predefined variable 
	assert(s.supported);
	assert(!s.stringIterator);
	assert(null == s.type);
	assert(null == s.iterator);

	i = snippets.determineSnippetInfo(null, loopCode, 418);
	assert(i.level == SnippetLevel.method);
	s = i.loopScope; // hash map
	assert(s.supported);
	assert(!s.stringIterator);
	assert(null == s.type);
	assert(s.iterator == "map");
	assert(s.numItems == 2);
}

enum StackStorageScope(string val) = "if (done) return; auto __" ~ val
	~ "_scope = " ~ val ~ "; scope (exit) if (!done) " ~ val ~ " = __" ~ val ~ "_scope;";
enum SnippetLevelWrapper(SnippetLevel level) = "if (done) return; pushLevel("
	~ level.stringof ~ ", dec); scope (exit) popLevel(dec); "
	~ "if (!dec.tokens.length || dec.tokens[0].index <= position) lastStatement = null;";
enum FullSnippetLevelWrapper(SnippetLevel level) = SnippetLevelWrapper!level ~ " super.visit(dec);";
enum MethodSnippetLevelWrapper(SnippetLevel level) = "repeatLastOnDeclStmt = true; scope(exit) repeatLastOnDeclStmt = false; " ~ FullSnippetLevelWrapper!level;

class SnippetInfoGenerator : ASTVisitor
{
	alias visit = ASTVisitor.visit;

	this(size_t position)
	{
		this.position = position;
	}

	static foreach (T; AliasSeq!(Declaration, ImportBindings, ImportBind, ModuleDeclaration))
		override void visit(const T dec)
		{
			mixin(FullSnippetLevelWrapper!(SnippetLevel.other));
		}

	override void visit(const MixinTemplateDeclaration dec)
	{
		mixin(SnippetLevelWrapper!(SnippetLevel.mixinTemplate));
		// avoid TemplateDeclaration overriding scope, immediately iterate over children
		if (dec.templateDeclaration)
			dec.templateDeclaration.accept(this);
	}

	override void visit(const StructBody dec)
	{
		mixin(FullSnippetLevelWrapper!(SnippetLevel.type));
	}

	static foreach (T; AliasSeq!(SpecifiedFunctionBody, Unittest))
		override void visit(const T dec)
		{
			mixin(StackStorageScope!"variableStack");
			mixin(SnippetLevelWrapper!(SnippetLevel.newMethod));
			mixin(FullSnippetLevelWrapper!(SnippetLevel.method));
		}

	override void visit(const StatementNoCaseNoDefault dec)
	{
		mixin(StackStorageScope!"variableStack");
		super.visit(dec);
	}

	override void visit(const DeclarationOrStatement dec)
	{
		if (repeatLastOnDeclStmt)
		{
			if (done) return;
			pushLevel(ret.stack[$ - 2], dec);
			scope (exit) popLevel(dec);
			super.visit(dec);
			if (!dec.tokens.length || dec.tokens[0].index <= position)
				lastStatement = cast()dec;
		}
		else
		{
			super.visit(dec);
			if (!dec.tokens.length || dec.tokens[0].index <= position)
				lastStatement = cast()dec;
		}
	}

	static foreach (T; AliasSeq!(ForeachStatement, ForStatement, WhileStatement, DoStatement))
		override void visit(const T dec)
		{
			mixin(MethodSnippetLevelWrapper!(SnippetLevel.loop));
		}

	override void visit(const SwitchStatement dec)
	{
		mixin(MethodSnippetLevelWrapper!(SnippetLevel.switch_));
	}

	static foreach (T; AliasSeq!(Arguments, ExpressionNode))
		override void visit(const T dec)
		{
			mixin(FullSnippetLevelWrapper!(SnippetLevel.value));
		}

	override void visit(const VariableDeclaration dec)
	{
		// not quite accurate for VariableDeclaration, should only be value after = sign
		mixin(SnippetLevelWrapper!(SnippetLevel.value));
		super.visit(dec);

		foreach (t; dec.declarators)
		{
			debug(TraceGenerator) trace("push variable ", variableStack.length, " ", t.name.text, " of type ",
					astToString(dec.type), " and value ", astToString(t.initializer));
			variableStack.assumeSafeAppend ~= VariableUsage(dec.type, t.name,
					t.initializer ? t.initializer.nonVoidInitializer : null);
		}

		if (dec.autoDeclaration)
			foreach (t; dec.autoDeclaration.parts)
			{
				debug(TraceGenerator) trace("push variable ", variableStack.length, " ", t.identifier.text,
						" of type auto and value ", astToString(t.initializer));
				variableStack.assumeSafeAppend ~= VariableUsage(dec.type, t.identifier,
						t.initializer ? t.initializer.nonVoidInitializer : null);
			}
	}

	ref inout(SnippetInfo) value() inout
	{
		return ret;
	}

	void pushLevel(SnippetLevel level, const BaseNode node)
	{
		if (done)
			return;
		debug(TraceGenerator) trace("push ", level, " on ", typeid(node).name, " ", current, " -> ", node.tokens[0].index);

		if (node.tokens.length)
		{
			current = node.tokens[0].index;
			if (current >= position)
			{
				done = true;
				debug(TraceGenerator) trace("done");
				return;
			}
		}
		ret.stack.assumeSafeAppend ~= level;
	}

	void popLevel(const BaseNode node)
	{
		if (done)
			return;
		debug(TraceGenerator) trace("pop from ", typeid(node).name, " ", current, " -> ",
				node.tokens[$ - 1].index + node.tokens[$ - 1].tokenText.length);

		if (node.tokens.length)
		{
			current = node.tokens[$ - 1].index + node.tokens[$ - 1].tokenText.length;
			if (current > position)
			{
				done = true;
				debug(TraceGenerator) trace("done");
				return;
			}
		}

		ret.stack.length--;
	}

	bool done;
	VariableUsage[] variableStack;
	DeclarationOrStatement lastStatement;
	bool repeatLastOnDeclStmt;
	size_t position, current;
	SnippetInfo ret;
}
