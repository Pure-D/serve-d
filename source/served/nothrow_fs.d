module served.nothrow_fs;

import served.logger;

public import fs = std.file;

import std.utf;

auto tryDirEntries(string path, fs.SpanMode mode, bool followSymlink = true)
{
	try
	{
		return nothrowDirIterator(fs.dirEntries(path, mode, followSymlink));
	}
	catch (fs.FileException)
	{
		return typeof(return).init;
	}
}

auto tryDirEntries(string path, string pattern, fs.SpanMode mode, bool followSymlink = true)
{
	try
	{
		return nothrowDirIterator(fs.dirEntries(path, pattern, mode, followSymlink));
	}
	catch (fs.FileException)
	{
		return typeof(return).init;
	}
}

private NothrowDirIterator!T nothrowDirIterator(T)(T range)
{
	return NothrowDirIterator!T(range);
}

private struct NothrowDirIterator(T)
{
@safe:
	T base;
	bool crashed;

public:
	@property bool empty()
	{
		try
		{
			return crashed || base.empty;
		}
		catch (fs.FileException)
		{
			return crashed = true;
		}
		catch (UTFException e)
		{
			(() @trusted => error("Got malformed UTF string in dirIterator, something has probably corrupted. " ~ e.toString))();
			return crashed = true;
		}
	}

	@property auto front()
	{
		try
		{
			return base.front;
		}
		catch (fs.FileException)
		{
			crashed = true;
		}
		catch (UTFException e)
		{
			(() @trusted => error("Got malformed UTF string in dirIterator, something has probably corrupted. " ~ e.toString))();
			crashed = true;
		}
		return fs.DirEntry.init;
	}

	void popFront()
	{
		try
		{
			base.popFront();
		}
		catch (fs.FileException)
		{
			crashed = true;
		}
		catch (UTFException e)
		{
			(() @trusted => error("Got malformed UTF string in dirIterator, something has probably corrupted. " ~ e.toString))();
			crashed = true;
		}
	}
}
