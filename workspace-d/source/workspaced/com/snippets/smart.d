module workspaced.com.snippets.smart;

debug = SnippetScope;

import workspaced.api;
import workspaced.com.snippets;

import std.algorithm;
import std.conv;
import std.string;

class SmartSnippetProvider : SnippetProvider
{
	Future!(Snippet[]) provideSnippets(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position, const SnippetInfo info)
	{
		Snippet[] res;

		if (info.loopScope.supported)
		{
			if (info.loopScope.numItems > 1)
			{
				res ~= ndForeach(info.loopScope.numItems, info.loopScope.iterator);
				res ~= simpleForeach();
				res ~= stringIterators();
			}
			else if (info.loopScope.stringIterator)
			{
				res ~= simpleForeach();
				res ~= stringIterators(info.loopScope.iterator);
			}
			else
			{
				res ~= simpleForeach(info.loopScope.iterator, info.loopScope.type);
				res ~= stringIterators();
			}
		}

		if (info.lastStatement.type == "IfStatement"
			&& !info.lastStatement.ifHasElse)
		{
			int ifIndex = info.contextTokenIndex == 0 ? position : info.contextTokenIndex;
			auto hasBraces = code[0 .. max(min(ifIndex, $), 0)].stripRight.endsWith("}");
			Snippet snp;
			snp.providerId = typeid(this).name;
			snp.id = "else";
			snp.title = "else";
			snp.shortcut = "else";
			snp.documentation = "else block";
			if (hasBraces)
			{
				snp.plain = "else {\n\t\n}";
				snp.snippet = "else {\n\t$0\n}";
			}
			else
			{
				snp.plain = "else\n\t";
				snp.snippet = "else\n\t$0";
			}
			snp.unformatted = true;
			snp.resolved = true;
			res ~= snp;
		}

		if (info.lastStatement.type == "TryStatement")
		{
			int tryIndex = info.contextTokenIndex == 0 ? position : info.contextTokenIndex;
			auto hasBraces = code[0 .. max(min(tryIndex, $), 0)].stripRight.endsWith("}");
			Snippet catchSnippet;
			catchSnippet.providerId = typeid(this).name;
			catchSnippet.id = "catch";
			catchSnippet.title = "catch";
			catchSnippet.shortcut = "catch";
			catchSnippet.documentation = "catch block";
			if (hasBraces)
			{
				catchSnippet.plain = "catch (Exception e) {\n\t\n}";
				catchSnippet.snippet = "catch (${1:Exception e}) {\n\t$0\n}";
			}
			else
			{
				catchSnippet.plain = "catch (Exception e)\n\t";
				catchSnippet.snippet = "catch (${1:Exception e})\n\t$0";
			}
			catchSnippet.unformatted = true;
			catchSnippet.resolved = true;
			res ~= catchSnippet;

			Snippet finallySnippet;
			finallySnippet.providerId = typeid(this).name;
			finallySnippet.id = "finally";
			finallySnippet.title = "finally";
			finallySnippet.shortcut = "finally";
			finallySnippet.documentation = "finally block";
			if (hasBraces)
			{
				finallySnippet.plain = "finally {\n\t\n}";
				finallySnippet.snippet = "finally {\n\t$0\n}";
			}
			else
			{
				finallySnippet.plain = "finally\n\t";
				finallySnippet.snippet = "finally\n\t$0";
			}
			finallySnippet.unformatted = true;
			finallySnippet.resolved = true;
			res ~= finallySnippet;
		}

		debug (SnippetScope)
		{
			import painlessjson : toJSON;

			Snippet ret;
			ret.providerId = typeid(this).name;
			ret.id = "workspaced-snippet-debug";
			ret.title = "[DEBUG] Snippet";
			ret.shortcut = "__debug_snippet";
			ret.plain = ret.snippet = info.toJSON.toPrettyString;
			ret.unformatted = true;
			ret.resolved = true;
			res ~= ret;
		}

		return typeof(return).fromResult(res.length ? res : null);
	}

	Future!Snippet resolveSnippet(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position,
			const SnippetInfo info, Snippet snippet)
	{
		return typeof(return).fromResult(snippet);
	}

	Snippet ndForeach(int n, string name = null)
	{
		Snippet ret;
		ret.providerId = typeid(this).name;
		ret.id = "nd";
		ret.title = "foreach over " ~ n.to!string ~ " keys";
		if (name.length)
			ret.title ~= " (over " ~ name ~ ")";
		ret.shortcut = "foreach";
		ret.documentation = "Foreach over locally defined variable with " ~ n.to!string ~ " keys.";
		string keys;
		if (n == 2)
		{
			keys = "key, value";
		}
		else if (n <= 4)
		{
			foreach (i; 0 .. n - 1)
			{
				keys ~= cast(char)('i' + i) ~ ", ";
			}
			keys ~= "value";
		}
		else
		{
			foreach (i; 0 .. n - 1)
			{
				keys ~= "k" ~ (i + 1).to!string ~ ", ";
			}
			keys ~= "value";
		}

		if (name.length)
		{
			ret.plain = "foreach (" ~ keys ~ "; " ~ name ~ ") {\n\t\n}";
			ret.snippet = "foreach (${1:" ~ keys ~ "}; ${2:" ~ name ~ "}) {\n\t$0\n}";
		}
		else
		{
			ret.plain = "foreach (" ~ keys ~ "; map) {\n\t\n}";
			ret.snippet = "foreach (${1:" ~ keys ~ "}; ${2:map}) {\n\t$0\n}";
		}
		ret.resolved = true;
		return ret;
	}

	Snippet simpleForeach(string name = null, string type = null)
	{
		Snippet ret;
		ret.providerId = typeid(this).name;
		ret.id = "simple";
		ret.title = "foreach loop";
		if (name.length)
			ret.title ~= " (over " ~ name ~ ")";
		ret.shortcut = "foreach";
		ret.documentation = name.length
			? "Foreach over locally defined variable." : "Foreach over a variable or range.";
		string t = type.length ? type ~ " " : null;
		if (name.length)
		{
			ret.plain = "foreach (" ~ t ~ "key; " ~ name ~ ") {\n\t\n}";
			ret.snippet = "foreach (" ~ t ~ "${1:key}; ${2:" ~ name ~ "}) {\n\t$0\n}";
		}
		else
		{
			ret.plain = "foreach (" ~ t ~ "key; list) {\n\t\n}";
			ret.snippet = "foreach (" ~ t ~ "${1:key}; ${2:list}) {\n\t$0\n}";
		}
		ret.resolved = true;
		return ret;
	}

	Snippet stringIterators(string name = null)
	{
		Snippet ret;
		ret.providerId = typeid(this).name;
		ret.id = "str";
		ret.title = "foreach loop";
		if (name.length)
			ret.title ~= " (unicode over " ~ name ~ ")";
		else
			ret.title ~= " (unicode)";
		ret.shortcut = "foreach_utf";
		ret.documentation = name.length
			? "Foreach over locally defined variable." : "Foreach over a variable or range.";
		if (name.length)
		{
			ret.plain = "foreach (char key; " ~ name ~ ") {\n\t\n}";
			ret.snippet = "foreach (${1|char,wchar,dchar|} ${2:key}; ${3:" ~ name ~ "}) {\n\t$0\n}";
		}
		else
		{
			ret.plain = "foreach (char key; str) {\n\t\n}";
			ret.snippet = "foreach (${1|char,wchar,dchar|} ${2:key}; ${3:str}) {\n\t$0\n}";
		}
		ret.resolved = true;
		return ret;
	}
}
