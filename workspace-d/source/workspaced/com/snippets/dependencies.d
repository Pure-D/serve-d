module workspaced.com.snippets.dependencies;

import workspaced.api;
import workspaced.com.dub;
import workspaced.com.snippets;

import std.algorithm;

///
alias SnippetList = const(PlainSnippet)[];

/// A list of dependencies usable in an associative array
struct DependencySet
{
	private string[] sorted;

	void set(scope const(string)[] deps)
	{
		sorted.length = deps.length;
		sorted[] = deps;
		sorted.sort!"a<b";
	}

	bool hasAll(scope string[] deps) const
	{
		deps.sort!"a<b";
		int a, b;
		while (a < sorted.length && b < deps.length)
		{
			const as = sorted[a];
			const bs = deps[b];
			const c = cmp(as, bs);

			if (c == 0)
			{
				a++;
				b++;
			}
			else if (c < 0)
				return false;
			else
				b++;
		}
		return a == sorted.length;
	}

	bool opEquals(const ref DependencySet other) const
	{
		return sorted == other.sorted;
	}

	size_t toHash() const @safe nothrow
	{
		size_t ret;
		foreach (v; sorted)
			ret ^= typeid(v).getHash((() @trusted => &v)());
		return ret;
	}
}

/// Representation for a plain snippet with required dependencies. Maps to the
/// parameters of `DependencyBasedSnippetProvider.addSnippet`.
struct DependencySnippet
{
	///
	const(string)[] requiredDependencies;
	///
	PlainSnippet snippet;
}

/// ditto
struct DependencySnippets
{
	///
	const(string)[] requiredDependencies;
	///
	const(PlainSnippet)[] snippets;
}

class DependencyBasedSnippetProvider : SnippetProvider
{
	SnippetList[DependencySet] snippets;

	void addSnippet(const(string)[] requiredDependencies, const PlainSnippet snippet)
	{
		DependencySet set;
		set.set(requiredDependencies);

		if (auto v = set in snippets)
			*v ~= snippet;
		else
			snippets[set] = [snippet];
	}

	Future!(Snippet[]) provideSnippets(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position, const SnippetInfo info)
	{
		if (!instance.has!DubComponent)
			return typeof(return).fromResult(null);
		else
		{
			string id = typeid(this).name;
			auto dub = instance.get!DubComponent;
			return typeof(return).async(delegate() {
				string[] deps;
				foreach (dep; dub.dependencies)
				{
					deps ~= dep.name;
					deps ~= dep.dependencies.keys;
				}
				Snippet[] ret;
				foreach (k, v; snippets)
				{
					if (k.hasAll(deps))
					{
						foreach (snip; v)
							if (snip.levels.canFind(info.level))
								ret ~= snip.buildSnippet(id);
					}
				}
				return ret;
			});
		}
	}

	Future!Snippet resolveSnippet(scope const WorkspaceD.Instance instance,
			scope const(char)[] file, scope const(char)[] code, int position,
			const SnippetInfo info, Snippet snippet)
	{
		snippet.resolved = true;
		return typeof(return).fromResult(snippet);
	}
}

unittest
{
	DependencySet set;
	set.set(["vibe-d", "mir", "serve-d"]);
	assert(set.hasAll(["vibe-d", "serve-d", "mir"]));
	assert(set.hasAll(["vibe-d", "serve-d", "serve-d", "serve-d", "mir", "mir"]));
	assert(set.hasAll(["vibe-d", "serve-d", "mir", "workspace-d"]));
	assert(set.hasAll(["diet-ng", "vibe-d", "serve-d", "mir", "workspace-d"]));
	assert(!set.hasAll(["diet-ng", "serve-d", "mir", "workspace-d"]));
	assert(!set.hasAll(["diet-ng", "serve-d", "vibe-d", "workspace-d"]));
	assert(!set.hasAll(["diet-ng", "mir", "mir", "vibe-d", "workspace-d"]));
	assert(!set.hasAll(["diet-ng", "mir", "vibe-d", "workspace-d"]));

	set.set(["vibe-d:http"]);
	assert(set.hasAll([
				"botan", "botan", "botan-math", "botan-math", "diet-ng", "diet-ng",
				"eventcore", "eventcore", "libasync", "libasync", "memutils",
				"memutils", "memutils", "mir-linux-kernel", "mir-linux-kernel",
				"openssl", "openssl", "openssl", "stdx-allocator", "stdx-allocator",
				"stdx-allocator", "taggedalgebraic", "taggedalgebraic", "vibe-core",
				"vibe-core", "vibe-d", "vibe-d:core", "vibe-d:core", "vibe-d:core",
				"vibe-d:core", "vibe-d:core", "vibe-d:core", "vibe-d:crypto",
				"vibe-d:crypto", "vibe-d:crypto", "vibe-d:data", "vibe-d:data",
				"vibe-d:data", "vibe-d:http", "vibe-d:http", "vibe-d:http", "vibe-d:http",
				"vibe-d:http", "vibe-d:inet", "vibe-d:inet", "vibe-d:inet", "vibe-d:inet",
				"vibe-d:mail", "vibe-d:mail", "vibe-d:mongodb", "vibe-d:mongodb",
				"vibe-d:redis", "vibe-d:redis", "vibe-d:stream", "vibe-d:stream",
				"vibe-d:stream", "vibe-d:stream", "vibe-d:textfilter", "vibe-d:textfilter",
				"vibe-d:textfilter", "vibe-d:textfilter", "vibe-d:tls", "vibe-d:tls",
				"vibe-d:tls", "vibe-d:tls", "vibe-d:utils", "vibe-d:utils", "vibe-d:utils",
				"vibe-d:utils", "vibe-d:utils", "vibe-d:utils", "vibe-d:web", "vibe-d:web"
			]));

	set.set(null);
	assert(set.hasAll([]));
	assert(set.hasAll(["foo"]));
}
