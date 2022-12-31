module workspaced.com.index;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import core.sync.mutex;
import std.algorithm;
import std.array;
import std.experimental.logger : trace;
import std.range;

import workspaced.api;
import workspaced.helpers;

import workspaced.com.dscanner;
import workspaced.com.moduleman;

@component("index")
class IndexComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		config.stringBehavior = StringBehavior.source;
	}

	Future!ModuleRef reindexFromDisk(string file)
	{
		import std.file : readText;

		if (!refInstance)
			throw new Exception("index.reindex requires to be instanced");

		try
		{
			auto content = readText(file);
			return reindex(file, content, true);
		}
		catch (Exception e)
		{
			return typeof(return).fromError(e);
		}
	}

	Future!ModuleRef reindex(string file, scope const(char)[] code, bool force)
	{
		if (!refInstance)
			throw new Exception("index.reindex requires to be instanced");

		auto mod = get!ModulemanComponent.getModule(code);

		auto store = getInstanceStore;

		if (mod is null)
		{
			if (!force)
				return typeof(return).fromResult(null);

			ImportCacheEntry entry;
			entry.success = false;
			entry.fileName = file;

			store.cache.require(mod, shared ImportCacheEntry(true, file)).replaceFrom(mod, entry, *store);
			return typeof(return).fromResult(mod);
		}
		else
		{
			auto ret = new typeof(return);
			auto entryTask = generateCacheEntry(file, code);
			entryTask.onDone(delegate() {
				try
				{
					auto entry = entryTask.moveImmediately;
					if (entry == ImportCacheEntry.init && !force)
						return ret.finish(null);

					store.cache
						.require(mod, shared ImportCacheEntry(true, file))
						.replaceFrom(mod, entry, *store);

					ret.finish(mod);
				}
				catch (Throwable t)
				{
					ret.error(t);
				}
			});
			return ret;
		}
	}

	void iterateAll(scope void delegate(const ModuleRef mod, string fileName, scope const ref DefinitionElement definition) cb)
	{
		auto store = getInstanceStore;
		foreach (mod, ref entry; store.cache)
		{
			if (!entry.success)
				continue;

			synchronized (store.cachesMutex)
			{
				foreach (scope ref d; entry._definitions)
					cb(mod, entry.fileName, cast()d);
			}
		}
	}

	void iterateDefinitions(ModuleRef mod, scope void delegate(scope const DefinitionElement definition) cb)
	{
		auto store = getInstanceStore;
		if (auto v = mod in store.cache)
		{
			if (!v.success)
				return;

			synchronized (store.cachesMutex)
			{
				foreach (scope ref d; v._definitions)
					cb(cast()d);
			}
		}
	}

	void iterateSymbolsStartingWith(string s, scope void delegate(string symbol, char type, scope const ModuleRef fromModule) cb)
	{
		getInstanceStore.iterateGlobalsStartingWith(s, (scope item) {
			cb(item.name, item.type, item.fromModule);
		});
	}

	void dropIndex(ModuleRef key)
	{
		if (!refInstance)
			throw new Exception("index.dropIndex requires to be instanced");

		store.require(refInstance).cache.remove(key);
	}

	Future!void autoIndexSources(string[] stdlib)
	{
		if (!refInstance)
			throw new Exception("index.autoIndexSources requires to be instanced");

		auto ret = new typeof(return)();
		gthreads.create({
			mixin(traceTask);
			try
			{
				auto files = appender!(string[]);
				foreach (path; stdlib)
					appendSourceFiles(files, path);
				foreach (path; importPaths())
					appendSourceFiles(files, path);
				files ~= importFiles();

				trace("Indexing ", files.data.length, " files inside ", refInstance.cwd, "...");

				auto tasks = files.data.map!(f => reindexFromDisk(f)).array;

				whenAllDone(tasks, {
					ret.finish();
				});
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	IndexHealthReport getHealth()
	{
		IndexHealthReport ret;
		auto s = getInstanceStore;
		synchronized (s.cachesMutex)
		{
			foreach (ref entry; s.cache.byValue)
			{
				if (entry.success)
				{
					ret.indexedModules++;
					ret.numDefinitions += entry._definitions.length;
					ret.numImports += entry._allImports.length;
				}
				else
				{
					ret.failedFiles ~= entry.fileName;
				}
			}
		}
		return ret;
	}

private:
	LexerConfig config;

	struct PerInstanceStore
	{
		@disable this();
		@disable this(this);

		struct InterestingGlobal
		{
			string name;
			ModuleRef fromModule;
			char type;

			this(ref const DefinitionElement def, ModuleRef sourceModule)
			{
				name = def.name;
				type = def.type;
				fromModule = sourceModule;
			}

			int opCmp(const InterestingGlobal other) const
			{
				if (name == other.name && fromModule == other.fromModule)
					return 0;
				else if (name == other.name)
					return fromModule < other.fromModule ? -1 : 1;
				else
					return name < other.name ? -1 : 1;
			}

			bool opEquals(const InterestingGlobal other) const
			{
				return name == other.name && fromModule == other.fromModule;
			}
		}

		this(bool ignored)
		{
			cachesMutex = new Mutex();
		}

		Mutex cachesMutex;
		shared(ImportCacheEntry)[ModuleRef] cache;

		ModuleRef[][ModuleRef] reverseImports;
		ModuleRef[][string] reverseDefinitions;
		InterestingGlobal[] allGlobals;

		void iterateGlobalsStartingWith(string s, scope void delegate(scope InterestingGlobal g) item)
		{
			if (!isInterestingGlobalName(s))
				return;

			synchronized (cachesMutex)
			{
				InterestingGlobal q;
				q.name = s;
				auto i = assumeSorted(allGlobals).lowerBound(q).length;
				while (i < allGlobals.length && allGlobals[i].name.startsWith(s))
				{
					item(allGlobals[i]);
					i++;
				}
			}
		}

		private void _addedImport(ref const ModuleRef mod, ModuleRef sourceModule)
		{
			insertSet(reverseImports.require(mod), sourceModule);
		}

		private void _removedImport(ref const ModuleRef mod, ModuleRef sourceModule)
		{
			removeSet(reverseImports.require(mod), sourceModule);
		}

		private void _addedDefinition(ref const DefinitionElement def, ModuleRef sourceModule)
		{
			insertSet(reverseDefinitions.require(def.name), sourceModule);
			if (isInterestingGlobal(def))
				insertSet(allGlobals, InterestingGlobal(def, sourceModule));
		}

		private void _removedDefinition(ref const DefinitionElement def, ModuleRef sourceModule)
		{
			removeSet(reverseDefinitions.require(def.name), sourceModule);
			if (isInterestingGlobal(def))
				removeSet(allGlobals, InterestingGlobal(def, sourceModule));
		}

		private static bool isInterestingGlobal(ref const DefinitionElement def)
		{
			return def.isImportable && def.visibility.isVisibleOutside
				&& isInterestingGlobalName(def.name);
		}

		private static bool isInterestingGlobalName(string name)
		{
			return name.length > 1 && name[0] != '_' && name != "this"
				&& isValidDIdentifier(name);
		}
	}

	PerInstanceStore[WorkspaceD.Instance] store;

	PerInstanceStore* getInstanceStore()
	{
		return &store.require(refInstance, PerInstanceStore(true));
	}

	Future!ImportCacheEntry generateCacheEntry(string file, scope const(char)[] code)
	{
		scope tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		if (!tokens.length)
			return typeof(return).fromResult(ImportCacheEntry.init);

		auto ret = new typeof(return);
		auto definitions = get!DscannerComponent.listDefinitions(file, code, true,
			ExtraMask.nullOnError | ExtraMask.imports | ExtraMask.includeFunctionMembers);
		definitions.onDone(delegate() {
			try
			{
				ImportCacheEntry result;
				result.fileName = file;
				result.success = true;
				result._definitions = definitions.getImmediately;
				result.generateImports();
				ret.finish(move(result));
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}
}

alias ModuleRef = const(string)[];

struct ImportCacheEntry
{
	bool success;
	string fileName;
	private ModuleRef[] _allImports;
	private DefinitionElement[] _definitions;

	@disable this(this);

	void replaceFrom(ModuleRef thisModule, ref ImportCacheEntry other, ref IndexComponent.PerInstanceStore cache) shared
	{
		other._allImports.sort!"a<b";
		other._definitions.sort!"a.name<b.name";

		success = other.success;
		fileName = other.fileName;
		synchronized (cache.cachesMutex)
		{
			auto newImports = move(other._allImports);
			auto newDefinitions = move(other._definitions);
			newImports.diffInto!("a<b", ModuleRef, ModuleRef)(
				(cast()this)._allImports, &cache._addedImport, &cache._removedImport,
				thisModule);
			newDefinitions.diffInto!("a.name<b.name", DefinitionElement, ModuleRef)(
				(cast()this)._definitions, &cache._addedDefinition, &cache._removedDefinition,
				thisModule);
		}
	}

	private void generateImports()
	{
		_allImports = null;
		foreach (def; _definitions)
		{
			if (def.type == 'I')
			{
				_allImports ~= def.name.split(".");
			}
		}
	}
}

private void diffInto(alias less = "a<b", T, Args...)(T[] from, ref T[] into,
	scope void delegate(ref T, Args) onAdded, scope void delegate(ref T, Args) onRemoved,
	Args extraArgs)
{
	import std.functional : binaryFun;

	size_t lhs, rhs;
	while (lhs < from.length && rhs < into.length)
	{
		if (binaryFun!less(from[lhs], into[rhs]))
		{
			onAdded(from[lhs], extraArgs);
			lhs++;
		}
		else if (binaryFun!less(into[rhs], from[lhs]))
		{
			onRemoved(into[rhs], extraArgs);
			rhs++;
		}
		else
		{
			lhs++;
			rhs++;
		}
	}

	if (lhs < from.length)
		foreach (ref a; from[lhs .. $])
			onAdded(a, extraArgs);
	if (rhs < into.length)
		foreach (ref a; into[rhs .. $])
			onRemoved(a, extraArgs);

	move(from, into);
}

/// Returns: [added, removed]
private T[][2] diffInto(alias less = "a<b", T)(scope return T[] from, ref scope return T[] into)
{
	T[] added, removed;
	diffInto!(less, T, typeof(null))(from, into, (ref v, _) { added ~= v; }, (ref v, _) { removed ~= v; }, null);
	return [added, removed];
}

unittest
{
	int[] result = [1];

	int[] a = [1, 2, 3];
	int[] b = [2, 3, 5];
	int[] c = [2, 3, 5, 5];
	int[] d = [2, 3, 4, 5, 5];
	int[] e = [1, 3, 5];
	int[] f = [];

	assert(a.diffInto(result) == [[2, 3], []]);
	assert(result == [1, 2, 3]);

	assert(b.diffInto(result) == [[5], [1]]);
	assert(result == [2, 3, 5]);

	assert(c.diffInto(result) == [[5], []]);
	assert(result == [2, 3, 5, 5]);

	assert(d.diffInto(result) == [[4], []]);
	assert(result == [2, 3, 4, 5, 5]);

	assert(e.diffInto(result) == [[1], [2, 4, 5]]);
	assert(result == [1, 3, 5]);

	assert(f.diffInto(result) == [[], [1, 3, 5]]);
	assert(result == []);
}

struct IndexHealthReport
{
	size_t indexedModules;
	size_t numImports;
	size_t numDefinitions;
	string[] failedFiles;
}

private void appendSourceFiles(R)(ref R range, string path)
{
	import std.file : exists, dirEntries, SpanMode;
	import std.path : extension;

	try
	{
		if (!exists(path))
			return;

		foreach (file; dirEntries(path, SpanMode.breadth))
		{
			if (!file.isFile)
				continue;
			if (file.extension == ".d" || file.extension == ".D")
				range ~= file;
		}
	}
	catch (Exception e)
	{
	}
}

private void insertSet(alias less = "a<b", T)(ref T[] arr, T item)
{
	import std.functional : binaryFun;

	if (arr.length == 0)
	{
		arr ~= item;
	}
	else if (arr.length == 1)
	{
		if (binaryFun!less(item, arr[0]))
			arr = item ~ arr;
		else
			arr ~= item;
	}
	else
	{
		auto i = assumeSorted!less(arr).lowerBound(item).length;
		if (i == arr.length)
			arr ~= item;
		else if (arr[i] != item)
			arr = arr[0 .. i] ~ item ~ arr[i .. $];
	}
}

private void removeSet(alias less = "a<b", T)(ref T[] arr, T item)
{
	if (arr.length == 0)
		return;
	else if (arr.length == 1)
	{
		if (arr[0] == item)
			arr.length = 0;
	}
	else
	{
		auto i = assumeSorted!less(arr).lowerBound(item).length;
		if (i != arr.length && arr[i] == item)
			arr = arr.remove(i);
	}
}

private bool isStdLib(const ModuleRef mod)
{
	return mod.length && mod[0].among!("std", "core", "etc", "object");
}
