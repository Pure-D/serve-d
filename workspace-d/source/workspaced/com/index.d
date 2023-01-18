module workspaced.com.index;

// version = TraceCache;
// version = BenchmarkLocalCachedIndexing;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import core.sync.mutex;
import std.algorithm;
import std.array;
import std.container.rbtree;
import std.conv;
import std.datetime.stopwatch;
import std.datetime.systime;
import std.experimental.logger : info, trace, warning;
import std.file;
import std.range;
import std.typecons;

import workspaced.api;
import workspaced.helpers;

import workspaced.com.dscanner;
import workspaced.com.moduleman;

private struct IndexCache
{
	import std.bitmanip;
	import std.file;
	import std.path;
	import std.stdio : File;

	static string defaultFilename()
	{
		import standardpaths;

		string cachePath;
		try
		{
			cachePath = writablePath(StandardPath.cache, FolderFlag.create);
			if (!cachePath.length)
				cachePath = writablePath(StandardPath.data, FolderFlag.create);
			if (!cachePath.length)
				cachePath = tempDir;
		}
		catch (Exception e)
		{
			warning("Failed to open writable cache path, falling back to tmp: ", e.msg);
			trace(e);
			cachePath = tempDir;
		}

		cachePath = buildPath(cachePath, "serve-d");
		if (!existsAndIsDir(cachePath))
			mkdir(cachePath);
		return buildPath(cachePath, "symbolindex.bin");
	}

	static struct IndexedFile
	{
		string fileName;
		SysTime lastModified;
		ulong fileSize;
		ModuleRef modName;

		DefinitionElement[] elements;
		bool hasMixin;

		bool opCast(T : bool)() const
		{
			return fileName.length > 0;
		}


		inout(ModuleDefinition) moduleDefinition() inout
		{
			return typeof(return)(elements, hasMixin);
		}
	}

	@disable this(this);

	this(Mutex mutex, string fileName)
	{
		assert(mutex);
		this.lookupMutex = mutex;
		this.fileName = fileName;
	}

	private Mutex lookupMutex;
	string fileName;
	private IndexedFile[] index;
	private size_t[string] lookup;
	private size_t appendOnly = size_t.max;

	private static immutable ubyte[4] headerMagic = ['S', 'v', 'D', 'x'];

	const(IndexedFile[]) getIndexedFiles() const
	{
		return index;
	}

	static IndexCache load()
	{
		return load(defaultFilename);
	}

	static IndexCache load(string fileName)
	{
		import std.stdio : File;

		try
		{
			IndexCache ret = IndexCache(new Mutex(), fileName);

			if (!existsAndIsFile(fileName))
				goto defaultReturn;

			scope f = File(fileName, "rb");
			ubyte[2048] stackBuffer;
			ubyte[] buffer = stackBuffer[];

			ubyte[] getBuffer(int length)
			{
				assert(length >= 0);
				while (length > buffer.length)
					buffer.length *= 2;
				return buffer[0 .. length];
			}

			ubyte[] readData(int length, lazy string reason, size_t line = __LINE__)
			{
				auto buf = getBuffer(length);
				auto ret = f.rawRead(buf);
				if (ret.length != buf.length)
				{
					assert(f.eof, "didn't read full buffer, but is not EOF!");
					throw new Exception("Unexpected EOF at " ~ f.tell.to!string
						~ " trying to read " ~ length.to!string ~ " bytes (got "
						~ ret.length.to!string ~ " bytes) for " ~ reason
						~ " (from " ~ __FILE__ ~ ":" ~ line.to!string ~ ")");
				}
				return ret;
			}

			ubyte[n] readDataFix(int n)(size_t line = __LINE__)
			{
				return readData(n, "readDataFix!" ~ n.stringof, line)[0 .. n];
			}

			auto header = readDataFix!8;
			if (header[0 .. 4] != headerMagic)
				throw new Exception("Didn't get magic header");
			ubyte formatVersion = header[4];
			ubyte serializeVersion = header[7];

			if (formatVersion != '1')
				throw new Exception("File format version unsupported");

			while (!f.eof)
			{
				auto fileOffset = f.tell;
				if (fileOffset >= f.size)
					break;
				IndexedFile idx;

				uint fileNameLen = readDataFix!4.littleEndianToNative!uint;
				idx.fileName = cast(string) readData(fileNameLen, "fileName from entry @" ~ fileOffset.to!string).idup;
				uint modNameLen = readDataFix!4.littleEndianToNative!uint;
				idx.modName = cast(string) readData(modNameLen, "modName from entry @" ~ fileOffset.to!string).idup;
				idx.lastModified = SysTime(readDataFix!8.littleEndianToNative!long);
				idx.fileSize = readDataFix!8.littleEndianToNative!ulong;
				auto flags = readDataFix!4;
				idx.hasMixin = flags[0] == 1;

				uint numItems = readDataFix!4.littleEndianToNative!uint;
				idx.elements.length = numItems;
				foreach (item; 0 .. numItems)
				{
					auto size = readDataFix!4.littleEndianToNative!uint;
					idx.elements[item] = DefinitionElement.deserialize(
						readData(size, "element " ~ (item + 1).to!string
							~ " / " ~ numItems.to!string
							~ " from entry @" ~ fileOffset.to!string),
						serializeVersion);
				}

				size_t i = ret.index.length;
				if (idx.fileName in ret.lookup)
					throw new Exception("Duplicate file cache entry for " ~ idx.fileName);
				ret.index ~= idx;
				ret.lookup[idx.fileName] = i;
			}
			ret.appendOnly = ret.index.length;
			return move(ret);
		}
		catch (Exception e)
		{
			info("Failed to parse IndexCache, rebuilding cache: ", e.msg);
			trace(e);
		}
	defaultReturn:
		return IndexCache(new Mutex(), defaultFilename);
	}

	void save()
	{
		if (appendOnly == index.length)
			return;

		try
		{
			string dir = dirName(fileName);
			if (!existsAndIsDir(dir))
				mkdir(dir);

			synchronized (lookupMutex)
			{
				if (appendOnly == index.length)
					return;

				if (appendOnly > index.length)
				{
					scope f = File(fileName, "w");
					scope w = f.lockingBinaryWriter;
					putHeader(w);
					foreach (ref i; index)
						putFile(w, i);
				}
				else
				{
					scope f = File(fileName, "a");
					scope w = f.lockingBinaryWriter;
					foreach (ref i; index[appendOnly .. $])
						putFile(w, i);
				}

				appendOnly = index.length;
			}
		}
		catch (Exception e)
		{
			appendOnly = size_t.max;
			warning("Failed to save symbol index: ", e.msg);
			trace(e);
		}
	}

	private void putHeader(W)(ref W writer)
	{
		// header format:
		// 4 bytes: ASCII "SvDx" (magic string)
		// 1 byte: format (container) version
		// under format version '1' (byte value 0x31):
		//   2 bytes: reserved
		//   1 byte: element version
		ubyte[8] data = 0;
		data[0 .. 4] = headerMagic;
		data[4] = '1';
		data[7] = DefinitionElement.serializeVersion;
		writer.rawWrite(data);
	}

	private void putFile(W)(ref W writer, ref IndexedFile idx)
	{
		with (writer)
		{
			rawWrite(nativeToLittleEndian(cast(uint) idx.fileName.length));
			rawWrite(cast(const(ubyte)[]) idx.fileName);
			rawWrite(nativeToLittleEndian(cast(uint) idx.modName.length));
			rawWrite(cast(const(ubyte)[]) idx.modName);
			rawWrite(nativeToLittleEndian(long(idx.lastModified.stdTime)));
			rawWrite(nativeToLittleEndian(ulong(idx.fileSize)));
			ubyte[4] flags;
			flags[0] = idx.hasMixin ? 1 : 0;
			rawWrite(flags);
			rawWrite(nativeToLittleEndian(cast(uint) idx.elements.length));
			foreach (e; idx.elements)
			{
				auto data = e.serialize;
				rawWrite(nativeToLittleEndian(cast(uint) data.length));
				rawWrite(data);
			}
		}
	}

	void setFile(string file, SysTime lastWrite, ulong fileSize, ModuleRef modName, DefinitionElement[] elements,
		bool hasMixin)
	{
		if (!lookupMutex)
			throw new Exception("Missing mutex on this instance");

		synchronized (lookupMutex)
		{
			if (auto existing = file in lookup)
			{
				if (index[*existing].lastModified == lastWrite
					&& index[*existing].fileSize == fileSize
					&& index[*existing].elements.length == elements.length)
					return;

				index[*existing] = IndexedFile(file, lastWrite, fileSize, modName, elements, hasMixin);
				appendOnly = size_t.max;
			}
			else
			{
				auto i = index.length;
				lookup[file] = i;
				index ~= IndexedFile(file, lastWrite, fileSize, modName, elements, hasMixin);
			}
		}
	}

	static Tuple!(string, SysTime, ulong) getFileMeta(string file)
	{
		ulong size;
		SysTime writeTime;
		if (!statFile(file, null, &writeTime, &size))
			return typeof(return).init;
		return tuple(file, writeTime, size);
	}

	const(IndexedFile) getIfActive(string file) const
	{
		if (!lookupMutex)
			throw new Exception("Missing mutex on this instance");

		bool hasExisting = !!(file in lookup);

		if (!hasExisting)
		{
			version (TraceCache)
				trace("Cache-miss: ", file, " (not present in saved cache)");
			return IndexedFile.init;
		}
		auto meta = getFileMeta(file);

		if (meta is typeof(meta).init)
		{
			version (TraceCache)
				trace("Cache-miss: ", file, " (file does not exist on filesystem)");
			return IndexedFile.init;
		}

		if (auto existing = file in lookup)
		{
			if (meta[1] == index[*existing].lastModified
				&& meta[2] == index[*existing].fileSize)
				return index[*existing];
			else version (TraceCache)
				trace("Cache-miss: ", file, " (mismatching lastModified or file size)");
		}
		else
		{
			trace("Cache-miss: ", file, " (not present in saved cache - late!!)");
		}
		return IndexedFile.init;
	}
}

@component("index")
class IndexComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		if (!refInstance)
			throw new Exception("index.reindex requires to be instanced");

		if (!fileIndex.lookupMutex)
		{
			trace("Loading file index from ", IndexCache.defaultFilename);
			StopWatch sw;
			sw.start();
			fileIndex = IndexCache.load();
			assert(fileIndex.index.length == fileIndex.lookup.length);
			trace("loaded file index with ", fileIndex.index.length, " entries in ", sw.peek);
		}

		allGlobals.initialize();
		cachesMutex = new Mutex();
		config.stringBehavior = StringBehavior.source;
	}

	Future!ModuleRef reindexFromDisk(string file)
	{
		import std.file : readText;

		try
		{
			if (auto cache = fileIndex.getIfActive(file))
			{
				auto modName = cache.modName;
				forceReindexFromCache(
					file,
					cache.lastModified,
					cache.fileSize,
					cache.modName,
					cache.moduleDefinition);
				return typeof(return).fromResult(modName);
			}
			else
			{
				auto meta = IndexCache.getFileMeta(file);
				if (meta is typeof(meta).init)
					throw new Exception("Failed to read file metadata");
				auto content = readText(file);
				return reindex(meta.expand, content, true);
			}
		}
		catch (Exception e)
		{
			trace("Index error in ", file, ": ", e);
			
			return typeof(return).fromError(e);
		}
	}

	Future!ModuleRef reindexSaved(string file, scope const(char)[] code)
	{
		auto meta = IndexCache.getFileMeta(file);
		if (meta is typeof(meta).init)
			throw new Exception("Cannot read file metadata from " ~ file);
		return reindex(meta.expand, code, true);
	}

	Future!ModuleRef reindex(string file, SysTime lastWrite, ulong fileSize, scope const(char)[] code, bool force)
	{
		auto mod = get!ModulemanComponent.moduleName(code);

		if (mod is null)
		{
			if (!force)
				return typeof(return).fromResult(null);

			ImportCacheEntry entry;
			entry.success = false;
			entry.fileName = file;

			synchronized (cachesMutex)
			{
				cache.require(mod, ImportCacheEntry(true, file)).replaceFrom(mod, entry, this);
			}
			return typeof(return).fromResult(mod);
		}
		else
		{
			auto ret = new typeof(return);
			auto entryTask = generateCacheEntry(file, lastWrite, fileSize, code);
			entryTask.onDone(delegate() {
				try
				{
					auto entry = entryTask.moveImmediately;
					if (entry == ImportCacheEntry.init && !force)
						return ret.finish(null);

					synchronized (cachesMutex)
					{
						cache
							.require(mod, ImportCacheEntry(true, file, lastWrite, fileSize))
							.replaceFrom(mod, entry, this);
					}

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

	private void forceReindexFromCache(string file, SysTime lastWrite, ulong fileSize, const ModuleRef mod, const ModuleDefinition cache)
	{
		synchronized (cachesMutex)
		{
			auto storeCacheEntry = &this.cache
				.require(mod, ImportCacheEntry(true, file, SysTime.init, 0));

			if (cast()storeCacheEntry.fileName == file
				&& cast()storeCacheEntry.lastModified == lastWrite
				&& cast()storeCacheEntry.fileSize == fileSize
				&& cast()storeCacheEntry._definitions.length == cache.definitions.length)
				return;

			ModuleDefinition duped;
			duped.hasMixin = cache.hasMixin;
			duped.definitions = new DefinitionElement[cache.definitions.length];
			foreach (i; 0 .. duped.length)
				duped.definitions[i] = cache.definitions[i].dup;

			auto entry = generateCacheEntry(file, lastWrite, fileSize, duped);
			this.cache[mod].replaceFrom(mod, entry, this);
		}
	}

	void saveIndex()
	{
		synchronized (cachesMutex)
		{
			foreach (mod, ref entry; cache)
				if (entry.success)
				{
					auto hasMixin = entry.isIncomplete;
					fileIndex.setFile(
						entry.fileName,
						cast()entry.lastModified,
						entry.fileSize,
						mod,
						cast(DefinitionElement[])entry._definitions,
						hasMixin);
				}
			fileIndex.save();
		}
		trace("Saved file index with ", fileIndex.index.length, " entries to ", fileIndex.fileName);
	}

	void iterateAll(scope void delegate(const ModuleRef mod, string fileName, scope const ref DefinitionElement definition) cb)
	{
		synchronized (cachesMutex)
		{
			foreach (mod, ref entry; cache)
			{
				if (!entry.success)
					continue;

				foreach (scope ref d; entry._definitions)
					cb(mod, entry.fileName, cast()d);
			}
		}
	}

	void iterateDefinitions(ModuleRef mod, scope void delegate(scope const DefinitionElement definition) cb)
	{
		synchronized (cachesMutex)
		{
			if (auto v = mod in cache)
			{
				if (!v.success)
					return;

				foreach (scope ref d; v._definitions)
					cb(cast()d);
			}
		}
	}

	void iterateSymbolsStartingWith(string s, scope void delegate(string symbol, char type, scope const ModuleRef fromModule) cb)
	{
		iterateGlobalsStartingWith(s, (scope item) {
			cb(item.name, item.type, item.fromModule);
		});
	}

	void iterateModuleReferences(ModuleRef mod, scope void delegate(ModuleRef definition) cb)
	{
		synchronized (cachesMutex)
		{
			if (auto v = mod in reverseImports)
				foreach (subMod; *v)
					cb(subMod);
		}
	}

	void iteratePublicImports(ModuleRef mod, scope void delegate(ModuleRef definition) cb)
	{
		synchronized (cachesMutex)
		{
			if (auto v = mod in cache)
			{
				if (!v.success)
					return;

				foreach (scope ref i; v._allImports)
					if (!i.insideAggregate && !i.insideFunction && i.visibility.isPublicImportVisibility)
						cb(cast()i.name);
			}
		}
	}

	void iteratePublicImportsRecursive(ModuleRef startMod, scope void delegate(ModuleRef parent, ModuleRef definition) cb)
	{
		synchronized (cachesMutex)
		{
			bool[ModuleRef] visited;
			ModuleRef[] stack = [startMod];
			while (stack.length)
			{
				auto mod = stack[$ - 1];
				stack.length--;
				if (mod in visited)
					continue;
				visited[mod] = true;
				if (auto v = mod in cache)
				{
					if (!v.success)
						return;

					foreach (scope ref i; v._allImports)
					{
						if (!i.insideAggregate && !i.insideFunction && i.visibility.isPublicImportVisibility)
						{
							cb(mod, cast()i.name);
							stack.assumeSafeAppend ~= cast()i.name;
						}
					}
				}
			}
		}
	}

	void iterateIncompleteModules(scope void delegate(ModuleRef definition) cb)
	{
		synchronized (cachesMutex)
		{
			foreach (mod, ref entry; cache)
			{
				if (entry.success && entry.isIncomplete)
					cb(mod);
			}
		}
	}

	void dropIndex(ModuleRef key)
	{
		synchronized (cachesMutex)
		{
			if (auto entry = key in cache)
			{
				ImportCacheEntry cleared;
				entry.replaceFrom(key, cleared, this);
				cache.remove(key);
			}
		}
	}

	string getIndexedFileName(ModuleRef forModule)
	{
		synchronized (cachesMutex)
		{
			if (auto entry = forModule in cache)
				return entry.fileName;
		}
		return null;
	}

	Future!void autoIndexSources(string[] stdlib, bool save)
	{
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
				foreach (file; importFiles())
					if (existsAndIsFile(file))
						files ~= file;

				StopWatch sw;
				sw.start();

				trace("Indexing ", files.data.length, " files inside workspace ", cwd, "...");

				auto tasks = files.data.map!(f => reindexFromDisk(f)).array;

				whenAllDone(tasks, {
					trace("Done indexing ", files.data.length, " files in ", sw.peek);
					if (save)
						saveIndex();
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
		synchronized (cachesMutex)
		{
			foreach (key, ref entry; cache)
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
	__gshared LexerConfig config;

	static struct InterestingGlobal
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

		int opCmp(ref const InterestingGlobal other) const
		{
			if (name < other.name)
				return -1;
			if (name > other.name)
				return 1;
			if (fromModule < other.fromModule)
				return -1;
			if (fromModule > other.fromModule)
				return 1;
			return 0;
		}

		bool opEquals(const InterestingGlobal other) const
		{
			return name == other.name && fromModule == other.fromModule;
		}
	}

	import std.experimental.allocator.gc_allocator;

	__gshared Mutex cachesMutex;
	__gshared ImportCacheEntry[ModuleRef] cache;

	__gshared RedBlackTree!ModuleRef[ModuleRef] reverseImports;
	__gshared RedBlackTree!ModuleRef[string] reverseDefinitions;
	__gshared OrderedKeyedList!InterestingGlobal allGlobals;

	version (unittest) void clearAll()
	{
		synchronized (cachesMutex)
		{
			cache = null;
			reverseImports = null;
			reverseDefinitions = null;
			allGlobals.clear();
			// fileIndex = IndexCache.load();
		}
	}

	void iterateGlobalsStartingWith(string s, scope void delegate(scope InterestingGlobal g) item)
	{
		if (!isInterestingGlobalName(s))
			return;

		synchronized (cachesMutex)
		{
			if (s.length == 0)
			{
				foreach (arr; allGlobals.allBuckets)
					foreach (ref g; arr)
						item(g);
			}
			else if (s.length == 1)
			{
				InterestingGlobal q;
				q.name = s;
				foreach (ref g; allGlobals.bucket(q))
					item(g);
			}
			else
			{
				InterestingGlobal q;
				q.name = s;
				auto bucket = allGlobals.bucket(q);
				auto i = assumeSorted(bucket).lowerBound(q).length;
				while (i < bucket.length && bucket.ptr[i].name.startsWith(s))
				{
					item(bucket.ptr[i]);
					i++;
				}
			}
		}
	}

	void _addedImport(ref const DefinitionElement modElem, ModuleRef sourceModule)
	{
		auto mod = modElem.name;
		auto ptr = &reverseImports.require(mod, new RedBlackTree!ModuleRef);
		ptr.insert(sourceModule);
		// insertSet(*ptr, sourceModule, 32);
	}

	void _removedImport(ref const DefinitionElement modElem, ModuleRef sourceModule)
	{
		auto mod = modElem.name;
		if (auto ptr = mod in reverseImports)
			ptr.removeKey(sourceModule);
			// removeSet(*ptr, sourceModule);
	}

	void _addedDefinition(ref const DefinitionElement def, ModuleRef sourceModule)
	{
		auto ptr = &reverseDefinitions.require(def.name, new RedBlackTree!ModuleRef);
		ptr.insert(sourceModule);
		// insertSet(*ptr, sourceModule, 64);
		if (isInterestingGlobal(def))
			allGlobals.insert(InterestingGlobal(def, sourceModule));
	}

	void _removedDefinition(ref const DefinitionElement def, ModuleRef sourceModule)
	{
		if (auto ptr = def.name in reverseDefinitions)
			ptr.removeKey(sourceModule);
			// removeSet(*ptr, sourceModule);
		if (isInterestingGlobal(def))
			allGlobals.remove(InterestingGlobal(def, sourceModule));
	}

	static bool isInterestingGlobal(ref const DefinitionElement def)
	{
		return def.isImportable && def.visibility.isVisibleOutside
			&& isInterestingGlobalName(def.name);
	}

	static bool isInterestingGlobalName(string name)
	{
		return name.length > 1 && name[0] != '_' && name != "this"
			&& isValidDIdentifier(name);
	}

	static __gshared IndexCache fileIndex;

	Future!ImportCacheEntry generateCacheEntry(string file, SysTime writeTime, ulong fileSize, scope const(char)[] code)
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
				auto modDef = definitions.getImmediately;
				modDef.definitions.sort!"a.cmpTypeAndName(b) < 0";
				ret.finish(generateCacheEntry(file, writeTime, fileSize, modDef));
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	ImportCacheEntry generateCacheEntry(string file, SysTime writeTime, ulong fileSize, ModuleDefinition elems)
	{
		ImportCacheEntry result;
		result.fileName = file;
		result.lastModified = writeTime;
		result.fileSize = fileSize;
		result.success = true;
		result.isIncomplete = elems.hasMixin;
		result._definitions = elems.definitions;
		return result;
	}
}

alias ModuleRef = string;

struct ImportCacheEntry
{
	bool success;
	string fileName;
	SysTime lastModified;
	ulong fileSize;
	bool isIncomplete;

	private DefinitionElement[] _allImports;
	private DefinitionElement[] _definitions;

	@disable this(this);

	private void replaceFrom(ModuleRef thisModule, ref ImportCacheEntry other, IndexComponent index)
	{
		other.generateImports();

		success = other.success;
		fileName = other.fileName;
		cast()lastModified = cast()other.lastModified;
		fileSize = other.fileSize;
		isIncomplete = other.isIncomplete;

		synchronized (index.cachesMutex)
		{
			auto newImports = move(other._allImports);
			auto newDefinitions = move(other._definitions);
			newImports.diffInto!("a.cmpTypeAndName(b) < 0", DefinitionElement, ModuleRef)(
				(cast()this)._allImports, &index._addedImport, &index._removedImport,
				thisModule);
			newDefinitions.diffInto!("a.cmpTypeAndName(b) < 0", DefinitionElement, ModuleRef)(
				(cast()this)._definitions, &index._addedDefinition, &index._removedDefinition,
				thisModule);
		}
	}

	private void generateImports()
	{
		_allImports = null;
		size_t start = -1;
		foreach (i, ref def; _definitions)
		{
			if (def.type == 'I')
			{
				if (start == -1)
					start = i;
			}
			else if (start != -1)
			{
				_allImports = _definitions[start .. i];
				return;
			}
		}

		if (start != -1)
			_allImports = _definitions[start .. $];
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
		if (binaryFun!less(from.ptr[lhs], into.ptr[rhs]))
		{
			onAdded(from.ptr[lhs], extraArgs);
			lhs++;
		}
		else if (binaryFun!less(into.ptr[rhs], from.ptr[lhs]))
		{
			onRemoved(into.ptr[rhs], extraArgs);
			rhs++;
		}
		else
		{
			lhs++;
			rhs++;
		}
	}

	if (lhs < from.length)
		foreach (ref a; from.ptr[lhs .. from.length])
			onAdded(a, extraArgs);
	if (rhs < into.length)
		foreach (ref a; into.ptr[rhs .. into.length])
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
		if (!existsAndIsDir(path))
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

private void insertSet(alias less = "a<b", T)(ref T[] arr, T item, int initialReserve)
{
	import std.functional : binaryFun;

	if (arr.length == 0)
	{
		arr.reserve(initialReserve);
		arr ~= move(item);
	}
	else
	{
		insertSortedNoDup!less(arr, move(item));
	}
}

private void removeSet(alias less = "a<b", T)(ref T[] arr, const auto ref T item)
{
	if (arr.length == 0)
		return;
	else if (arr.length == 1)
	{
		if (arr.ptr[0] == item)
		{
			arr.length = 0;
			arr = arr.assumeSafeAppend;
		}
	}
	else
	{
		auto i = assumeSorted!less(arr).lowerBound(item).length;
		if (i != arr.length && arr.ptr[i] == item)
		{
			arr = arr.remove(i);
			arr = arr.assumeSafeAppend;
		}
	}
}

bool isStdLib(const ModuleRef mod)
{
	return mod.startsWith("std.", "core.", "etc.") || mod == "object";
}

string getModuleSortKey(const ModuleRef mod)
{
	if (mod.startsWith("std."))
		return "1_";
	else if (mod.startsWith("core.", "etc."))
		return "2_";
	else
		return "3_";
}

struct OrderedKeyedList(T, alias key = "a.name")
{
	import std.functional;

	// 0-9 = '0'-'9'
	// 10-35 = 'A'-'Z'
	// 36 = '_'
	// 37-62 = 'a'-'z'
	// 63 = other
	T[][10 + 26 * 2 + 2] allBuckets;
	// RedBlackTree!T[10 + 26 * 2 + 2] allBuckets;
	// RedBlackTree!T allBuckets;

	void initialize()
	{
		// allBuckets = new RedBlackTree!T;
		// foreach (ref v; allBuckets)
		// 	v = new RedBlackTree!T;
	}

	ref auto bucket(const ref T item)
	{
		auto name = unaryFun!key(item);
		assert(name.length);
		char key = name[0];
		if (key >= '0' && key <= '9')
			return allBuckets[key - '0'];
		else if (key >= 'A' && key <= 'Z')
			return allBuckets[key - 'A' + 10];
		else if (key == '_')
			return allBuckets[36];
		else if (key >= 'a' && key <= 'z')
			return allBuckets[key - 'a' + 37];
		else
			return allBuckets[63];
	}

	void clear()
	{
		// allBuckets.clear();
		foreach (v; allBuckets)
		{
			// v.clear();
			v.length = 0;
		}
	}

	void insert(T item)
	{
		// allBuckets.insert(item);
		insertSet(bucket(item), item, 4096);
		// bucket(item).insert(item);
	}

	void remove(T item)
	{
		// allBuckets.removeKey(item);
		removeSet(bucket(item), item);
		// bucket(item).removeKey(item);
	}

	size_t totalCount() const @property
	{
		return allBuckets[].map!"a.length".sum;
		// return allBuckets.length;
	}
}

version (BenchmarkLocalCachedIndexing)
unittest
{
	import std.stdio;
	import std.experimental.logger;

	globalLogLevel = LogLevel.trace;

	static if (__VERSION__ < 2101)
		sharedLog = new FileLogger(stderr);
	else
		sharedLog = (() @trusted => cast(shared) new FileLogger(stderr))();

	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!IndexComponent;
	backend.register!DscannerComponent;
	backend.register!ModulemanComponent;
	IndexComponent index = instance.get!IndexComponent;
	StopWatch sw;

	foreach (i; 0 .. 11)
	{
		index.clearAll();
		if (i != 0)
			sw.start();
		index.autoIndexSources([
			"/usr/include/dlang/dmd"
		], i == 0).getBlocking();
		if (i != 0)
			sw.stop();
		writeln("all globals: ", index.allGlobals.totalCount);
		if (i == 0)
		{
			import core.thread;
			Thread.sleep(1.seconds);
		}
	}
	writeln("Total indexing time: ", sw.peek);
}
