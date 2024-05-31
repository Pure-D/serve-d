module workspaced.index_format;

import core.sync.mutex;
import std.algorithm;
import std.conv;
import std.datetime.systime;
import std.experimental.logger;
import std.sumtype;
import std.traits;
import std.typecons;

import workspaced.helpers;

alias ModuleRef = string;

struct IndexCache
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

	bool opCast(T : bool)() const
	{
		return lookupMutex !is null;
	}

	const(IndexedFile[]) getIndexedFiles() const
	{
		return index;
	}

	size_t indexCount() const
	{
		return getIndexedFiles.length;
	}

	static IndexCache load()
	{
		return load(defaultFilename);
	}

	static IndexCache load(string fileName)
	out (ret; ret.indexCount == ret.lookup.length)
	do
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


/// Returned by list-definitions
struct DefinitionElement
{
	import msgpack;

	enum BasicVisibility
	{
		default_,
		export_,
		public_,
		protected_,
		private_,
	}

	struct PackageVisibility
	{
		/// null or package name
		string packageName;
	}

	alias Visibility = SumType!(typeof(null), BasicVisibility, PackageVisibility);

	DefinitionElement dup() const
	{
		DefinitionElement ret;
		foreach (i, v; this.tupleof)
		{
			static if (is(typeof(ret.tupleof[i]) == string[string]))
			{
				foreach (k, subV; v)
					ret.tupleof[i][k] = subV;
			}
			else
				ret.tupleof[i] = v;
		}
		return ret;
	}

	int cmpTypeAndName(ref DefinitionElement rhs)
	{
		if (type < rhs.type)
			return -1;
		if (type > rhs.type)
			return 1;
		if (name < rhs.name)
			return -1;
		if (name > rhs.name)
			return 1;
		return 0;
	}

	///
	string name;
	/// 1-based line number
	int line;
	/// One of
	/// * `c` = class
	/// * `s` = struct
	/// * `i` = interface
	/// * `T` = template
	/// * `f` = function/ctor/dtor
	/// * `g` = enum {}
	/// * `u` = union
	/// * `e` = enum member/definition
	/// * `v` = variable
	/// * `a` = alias
	/// * `U` = unittest (only in verbose mode)
	/// * `D` = debug specification (only in verbose mode)
	/// * `V` = version specification (only in verbose mode)
	/// * `C` = static module ctor (only in verbose mode)
	/// * `S` = shared static module ctor (only in verbose mode)
	/// * `Q` = static module dtor (only in verbose mode)
	/// * `W` = shared static module dtor (only in verbose mode)
	/// * `P` = postblit/copy ctor (only in verbose mode)
	/// * `I` = import (only in verbose mode)
	/// * `N` = invariant
	/// * `:` = attribute declaration like `private:` (only in verbose mode)
	char type;
	/// Arbitrary per-symbol data that differs from type to type.
	string[string] attributes;
	///
	int[2] range;

	bool isVerboseType() const
	{
		import std.ascii : isUpper;

		return type != 'T' && isUpper(type);
	}

	/// `true` if this definition is within a method, lambda, unittest, ctor,
	/// dtor or other callable, where you can't access the type outside the
	/// function.
	bool insideFunction;
	/// `true` if this definition is within an aggregate (class, struct, etc) or
	/// template.
	bool insideAggregate;

	@serializedAs!SumTypePackProxy
	Visibility visibility;

	struct VersionCondition
	{
		string identifier;
		bool inverted;
	}

	/// List of `version (...)` identifiers that this symbol is inside.
	const(VersionCondition)[] versioned;
	/// List of `debug (...)` identifiers that this symbol is inside.
	const(VersionCondition)[] debugVersioned;
	/// True if this statement is defined within a `static if` or otherwise
	/// somehow potentially omitted depending on compile time constructs.
	bool hasOtherConditional;

	/// `true` if this symbol may not be available, depending on compile time
	/// conditional values or target platform. (also true for `version (all)`)
	/// See_Also: $(LREF versioned), $(LREF debugVersioned),
	/// $(LREF otherConditional)
	bool isConditional() const @property
	{
		return versioned.length || debugVersioned.length || hasOtherConditional;
	}

	bool isImportable() const @property
	{
		if (insideFunction || insideAggregate)
			return false;
		return !!type.among!('c', 's', 'i', 'T', 'f', 'g', 'u', 'e', 'v', 'a', 'D', 'V');
	}

	enum ubyte serializeVersion = 2;
	static assert(hashFields!(typeof(this).tupleof) == 0x2C31CF10C11B7E9B,
		"Updated fields or layout, but not version and hash! Please update serializeVersion and adjust this check to 0x"
		~ hashFields!(typeof(this).tupleof).to!string(16) ~ "\n\nFields layout: " ~ describeFields!(typeof(this).tupleof));

	ubyte[] serialize()
	{
		return pack(this);
	}

	static DefinitionElement deserialize(scope const(ubyte)[] data, int targetSerializeVersion)
	{
		if (targetSerializeVersion != serializeVersion)
			throw new Exception(text(
				"DefinitionElement cache format has changed, can't deserialize (file: ",
				targetSerializeVersion, ", impl: ", serializeVersion, ")"));

		static struct DefinitionElementUnqual
		{
			static foreach (i, t; DefinitionElement.tupleof)
			{
				static if (is(typeof(t) == const(VersionCondition)[]))
					mixin("VersionCondition[] ", __traits(identifier, DefinitionElement.tupleof[i]), ";");
				else static if (is(typeof(t) == Visibility))
					mixin("@serializedAs!SumTypePackProxy Visibility ", __traits(identifier, DefinitionElement.tupleof[i]), ";");
				else
					mixin("Unqual!(typeof(t)) ", __traits(identifier, DefinitionElement.tupleof[i]), ";");
			}
		}

		return DefinitionElement(unpack!DefinitionElementUnqual(data).tupleof);
	}
}

struct ModuleDefinition
{
	DefinitionElement[] definitions;
	bool hasMixin;

	alias definitions this;
}

private static ulong hashFields(Args...)()
{
	import std.bitmanip;
	import std.digest.crc : CRC64ISO;

	CRC64ISO crc;
	crc.put((cast(uint) Args.length).nativeToLittleEndian);
	static foreach (Arg; Args)
	{
		crc.put(cast(const(ubyte)[]) __traits(identifier, Arg));
		crc.put(cast(const(ubyte)[]) typeof(Arg).stringof);
	}
	return crc.finish.littleEndianToNative!ulong;
}

private static string describeFields(Args...)()
{
	import std.conv;

	string ret = "Total fields: " ~ Args.length.to!string;
	static foreach (Arg; Args)
	{
		ret ~= "\n- " ~ typeof(Arg).stringof ~ " " ~ __traits(identifier, Arg);
	}
	return ret;
}

private static struct SumTypePackProxy
{
	import msgpack;

	static void serialize(T)(ref Packer p, in T sumtype)
	{
		static assert(__traits(identifier, sumtype.tupleof[1]) == "tag");
		p.pack(sumtype.tupleof[1]);
		sumtype.match!((v) {
			static if (!is(typeof(v) == typeof(null)))
				p.pack(v);
		});
	}

	static void deserialize(T)(ref Unpacker u, ref T sumtype)
	{
		static assert(__traits(identifier, sumtype.tupleof[1]) == "tag");
		typeof(sumtype.tupleof[1]) tag;
		u.unpack(tag);
		S: switch (tag)
		{
			static foreach (i, U; T.Types)
			{
			case cast(typeof(tag))i:
				U value;
				static if (!is(U == typeof(null)))
					u.unpack(value);
				sumtype = value;
				break S;
			}
		default:
			throw new ConvException("Unsupported SumType value.");
		}
	}
}
