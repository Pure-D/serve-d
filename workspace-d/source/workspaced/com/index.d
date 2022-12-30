module workspaced.com.index;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import core.sync.mutex;
import std.algorithm;
import std.array;
import std.experimental.logger : trace;

import workspaced.api;

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

		if (mod is null)
		{
			if (!force)
				return typeof(return).fromResult(null);

			ImportCacheEntry entry;
			entry.success = false;
			entry.fileName = file;

			store.require(refInstance).cache.require(mod, shared ImportCacheEntry(true, file, new shared Mutex())).moveFrom(entry);
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

					store.require(refInstance).cache
						.require(mod, shared ImportCacheEntry(true, file, new shared Mutex()))
						.moveFrom(entry);

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
		auto cache = store.require(refInstance).cache;
		foreach (mod, ref entry; cache)
		{
			if (!entry.success)
				continue;

			synchronized (entry.syncObject)
			{
				foreach (scope ref d; entry._definitions)
					cb(mod, entry.fileName, cast()d);
			}
		}
	}

	void iterateDefinitions(ModuleRef mod, scope void delegate(scope const DefinitionElement definition) cb)
	{
		if (auto v = mod in store.require(refInstance).cache)
		{
			if (!v.success)
				return;

			synchronized (v.syncObject)
			{
				foreach (scope ref d; v._definitions)
					cb(cast()d);
			}
		}
	}

	void dropIndex(ModuleRef key)
	{
		if (!refInstance)
			throw new Exception("index.dropIndex requires to be instanced");

		store.require(refInstance).cache.remove(key);
	}

	Future!void autoIndexSources()
	{
		if (!refInstance)
			throw new Exception("index.autoIndexSources requires to be instanced");

		auto ret = new typeof(return)();
		gthreads.create({
			mixin(traceTask);
			try
			{
				auto files = appender!(string[]);
				files ~= importFiles();
				foreach (path; importPaths())
					appendSourceFiles(files, path);

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
		auto s = store.require(refInstance);
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
		return ret;
	}

private:
	LexerConfig config;

	struct PerInstanceStore
	{
		shared(ImportCacheEntry)[ModuleRef] cache;
	}

	PerInstanceStore[WorkspaceD.Instance] store;

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
	private Mutex syncObject;
	private ModuleRef[] _allImports;
	private DefinitionElement[] _definitions;

	@disable this(this);

	void moveFrom(ref ImportCacheEntry other) shared
	{
		success = other.success;
		fileName = other.fileName;
		assert(!other.syncObject);
		synchronized (syncObject)
		{
			_allImports = cast(shared)move(other._allImports);
			_definitions = cast(shared)move(other._definitions);
		}
	}

	private void generateImports()
	{
		_allImports = null;
		foreach (def; _definitions)
		{
			if (def.type.length == 1 && def.type[0] == 'I')
			{
				_allImports ~= def.name.split(".");
			}
		}
	}
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
