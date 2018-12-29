module served.commands.file_search;

import served.extension;
import served.types;
import served.filereader;

import workspaced.api;
import workspaced.coms;

import std.algorithm : sort, uniq, startsWith, endsWith;
import std.path : isAbsolute, buildPath, buildNormalizedPath, stripExtension, baseName;
import std.string : translate, makeTransTable;

import fs = std.file;
import io = std.stdio;

@protocolMethod("served/searchFile")
string[] searchFile(string query)
{
	if (!query.length)
		return null;

	if (query.isAbsolute)
	{
		if (fs.exists(query))
			return [query];
		else
			return null;
	}

	string[] ret;
	string[] importFiles, importPaths;
	importPaths = selectedWorkspace.config.stdlibPath();

	foreach (instance; backend.instances)
	{
		importFiles ~= instance.importFiles;
		importPaths ~= instance.importPaths;
	}

	importFiles.sort!"a<b";
	importPaths.sort!"a<b";

	foreach (file; importFiles.uniq)
	{
		if (fs.exists(file) && fs.isFile(file))
			if (file.endsWith(query))
			{
				auto rest = file[0 .. $ - query.length];
				if (!rest.length || rest.endsWith("/", "\\"))
					ret ~= file;
			}
	}
	foreach (dir; importPaths.uniq)
	{
		if (fs.exists(dir) && fs.isDir(dir))
			foreach (filename; fs.dirEntries(dir, fs.SpanMode.breadth))
				if (filename.isFile)
				{
					auto file = buildPath(dir, filename);
					if (file.endsWith(query))
					{
						auto rest = file[0 .. $ - query.length];
						if (!rest.length || rest.endsWith("/", "\\"))
							ret ~= file;
					}
				}
	}

	return ret;
}

private string[] cachedModuleFiles;
private string[string] modFileCache;
@protocolMethod("served/findFilesByModule")
string[] findFilesByModule(string module_)
{
	if (!module_.length)
		return null;

	if (auto cache = module_ in modFileCache)
		return [*cache];

	ubyte[] buffer = new ubyte[8 * 1024];
	scope (exit)
		buffer.destroy();

	string[] ret;
	string[] importFiles, importPaths;
	importPaths = selectedWorkspace.config.stdlibPath();

	foreach (instance; backend.instances)
	{
		importFiles ~= instance.importFiles;
		importPaths ~= instance.importPaths;
	}

	importFiles.sort!"a<b";
	importPaths.sort!"a<b";

	foreach (file; importFiles.uniq)
	{
		if (cachedModuleFiles.binarySearch(file) >= 0)
			continue;
		if (fs.exists(file) && fs.isFile(file))
		{
			auto fileMod = backend.get!ModulemanComponent.moduleName(
					cast(string) file.readCodeWithBuffer(buffer));
			if (fileMod.startsWith("std"))
			{
				modFileCache[fileMod] = file;
				cachedModuleFiles.insertSorted(file);
			}
			if (fileMod == module_)
				ret ~= file;
		}
	}
	foreach (dir; importPaths.uniq)
	{
		if (fs.exists(dir) && fs.isDir(dir))
			foreach (filename; fs.dirEntries(dir, fs.SpanMode.breadth))
				if (filename.isFile)
				{
					auto file = buildPath(dir, filename);
					if (cachedModuleFiles.binarySearch(file) >= 0)
						continue;
					auto fileMod = moduleNameForFile(file, dir, buffer);
					if (fileMod.startsWith("std"))
					{
						modFileCache[fileMod] = file;
						cachedModuleFiles.insertSorted(file);
					}
					if (fileMod == module_)
						ret ~= file;
				}
	}

	return ret;
}

private string moduleNameForFile(string file, string dir, ref ubyte[] buffer)
{
	auto ret = backend.get!ModulemanComponent.moduleName(
			cast(string) file.readCodeWithBuffer(buffer));
	if (ret.length)
		return ret;
	file = buildNormalizedPath(file);
	dir = buildNormalizedPath(dir);
	if (file.startsWith(dir))
		return file[dir.length .. $].stripExtension.translate(makeTransTable("/\\", ".."));
	else
		return baseName(file).stripExtension;
}
