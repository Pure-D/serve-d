module served.utils.stdlib_detect;

import std.algorithm : countUntil, splitter, startsWith;
import std.array : appender, replace;
import std.ascii : isWhite;
import std.conv : to;
import std.path : buildNormalizedPath, buildPath, chainPath, dirName;
import std.process : environment;
import std.string : indexOf, startsWith, strip, stripLeft;
import std.uni : sicmp;
import std.utf : decode, UseReplacementDchar;

import fs = std.file;
import io = std.stdio;

string[] autoDetectStdlibPaths(string cwd = null)
{
	string[] ret;
	if (detectDMDStdlibPaths(cwd, ret) || detectLDCStdlibPaths(cwd, ret))
	{
		return ret;
	}
	else
	{
		version (Windows)
			return [`C:\D\dmd2\src\druntime\import`, `C:\D\dmd2\src\phobos`];
		else version (OSX)
			return [`/Library/D/dmd/src/druntime/import`, `/Library/D/dmd/src/phobos`];
		else version (Posix)
			return [`/usr/include/dmd/druntime/import`, `/usr/include/dmd/phobos`];
		else
		{
			pragma(msg, __FILE__ ~ "(" ~ __LINE__
					~ "): Note: Unknown target OS. Please add default D stdlib path");
			return [];
		}
	}
}

bool detectDMDStdlibPaths(string cwd, out string[] ret)
{
	// https://dlang.org/dmd-linux.html#dmd-conf
	// https://dlang.org/dmd-osx.html#dmd-conf
	// https://dlang.org/dmd-windows.html#sc-ini

	version (Windows)
	{
		static immutable confName = "sc.ini";
		static immutable dmdExe = "dmd.exe";
	}
	else
	{
		static immutable confName = "dmd.conf";
		static immutable dmdExe = "dmd";
	}

	if (cwd.length && fs.exists(chainPath(cwd, confName))
			&& parseDmdConfImports(buildPath(cwd, confName), cwd, ret))
		return true;

	string home = environment.get("HOME");
	if (home.length && fs.exists(chainPath(home, confName))
			&& parseDmdConfImports(buildPath(home, confName), home, ret))
		return true;

	auto dmdPath = searchPathFor(dmdExe);
	if (dmdPath.length)
	{
		auto dmdDir = dirName(dmdPath);
		if (fs.exists(chainPath(dmdDir, confName))
				&& parseDmdConfImports(buildPath(dmdDir, confName), dmdDir, ret))
			return true;
	}

	version (Windows)
	{
		if (dmdPath.length)
		{
			auto dmdDir = dirName(dmdPath);
			bool haveDRuntime = fs.exists(chainPath(dmdDir, "..", "..", "src",
					"druntime", "import"));
			bool havePhobos = fs.exists(chainPath(dmdDir, "..", "..", "src", "phobos"));
			if (haveDRuntime && havePhobos)
				ret = [
					buildNormalizedPath(dmdDir, "..", "..", "src", "druntime",
							"import"),
					buildNormalizedPath(dmdDir, "..", "..", "src", "phobos")
				];
			else if (haveDRuntime)
				ret = [
					buildNormalizedPath(dmdDir, "..", "..", "src", "druntime", "import")
				];
			else if (havePhobos)
				ret = [buildNormalizedPath(dmdDir, "..", "..", "src", "phobos")];

			return ret.length > 0;
		}
		else
		{
			return false;
		}
	}
	else version (Posix)
	{
		if (fs.exists("/etc/dmd.conf") && parseDmdConfImports("/etc/dmd.conf", "/etc", ret))
			return true;

		return false;
	}
	else
	{
		pragma(msg,
				__FILE__ ~ "(" ~ __LINE__
				~ "): Note: Unknown target OS. Please add default dmd stdlib path");
		return false;
	}
}

bool detectLDCStdlibPaths(string cwd, out string[] ret)
{
	// https://github.com/ldc-developers/ldc/blob/829dc71114eaf7c769208f03eb9a614dafd789c3/driver/configfile.cpp

	static bool tryPath(R)(R path, lazy scope const(char)[] pathDir, out string[] ret)
	{
		return fs.exists(path) && parseLdcConfImports(path.to!string, pathDir, ret);
	}

	static immutable confName = "ldc2.conf";
	version (Windows)
	{
		static immutable ldcExe = "ldc2.exe";
		static immutable ldcExeAlt = "ldc.exe";
	}
	else
	{
		static immutable ldcExe = "ldc2";
		static immutable ldcExeAlt = "ldc";
	}

	auto ldcPath = searchPathFor(ldcExe);
	if (!ldcPath.length)
		ldcPath = searchPathFor(ldcExeAlt);
	auto ldcDir = ldcPath.length ? dirName(ldcPath) : null;

	if (tryPath(chainPath(cwd, confName), ldcDir, ret))
		return true;

	if (ldcPath.length)
	{
		if (tryPath(chainPath(ldcDir, confName), ldcDir, ret))
			return true;
	}

	string home = getUserHomeDirectoryLDC();
	if (home.length)
	{
		if (tryPath(chainPath(home, ".ldc", confName), ldcDir, ret))
			return true;

		version (Windows)
		{
			if (tryPath(chainPath(home, confName), ldcDir, ret))
				return true;
		}
	}

	if (ldcPath.length)
	{
		if (tryPath(chainPath(ldcDir.dirName, "etc", confName), ldcDir, ret))
			return true;
	}

	version (Windows)
	{
		string path = readLdcPathFromRegistry();
		if (path.length && tryPath(chainPath(path, "etc", confName), ldcDir, ret))
			return true;
	}
	else
	{
		if (tryPath(chainPath("/etc", confName), ldcDir, ret))
			return true;
		if (tryPath(chainPath("/etc/ldc", confName), ldcDir, ret))
			return true;
	}

	return false;
}

version (Windows) private string readLdcPathFromRegistry()
{
	import std.windows.registry;

	// https://github.com/ldc-developers/ldc/blob/829dc71114eaf7c769208f03eb9a614dafd789c3/driver/configfile.cpp#L65
	try
	{
		scope Key hklm = Registry.localMachine;
		scope Key val = hklm.getKey(`SOFTWARE\ldc-developers\LDC\0.11.0`, REGSAM.KEY_QUERY_VALUE);
		return val.getValue("Path").value_SZ();
	}
	catch (RegistryException)
	{
		return null;
	}
}

private string getUserHomeDirectoryLDC()
{
	version (Windows)
	{
		import core.sys.windows.windows;
		import core.sys.windows.shlobj;

		wchar[MAX_PATH] buf;
		HRESULT res = SHGetFolderPathW(null, CSIDL_FLAG_CREATE | CSIDL_APPDATA, null, SHGFP_TYPE
				.SHGFP_TYPE_CURRENT, buf.ptr);
		if (res != S_OK)
			return null;

		auto len = buf[].countUntil(wchar('\0'));
		if (len == -1)
			len = buf.length;
		return buf[0 .. len].to!string;
	}
	else
	{
		string home = environment.get("HOME");
		return home.length ? home : "/";
	}
}

private string searchPathFor()(scope const(char)[] executable)
{
	auto path = environment.get("PATH");

	version (Posix)
		char separator = ':';
	else version (Windows)
		char separator = ';';
	else
		static assert(false, "No path separator character");

	foreach (dir; path.splitter(separator))
	{
		auto execPath = buildPath(dir, executable);
		if (fs.exists(execPath))
			return execPath;
	}

	return null;
}

deprecated bool parseDmdConfImports(R)(R path, out string[] paths)
{
	return parseDmdConfImports(path, dirName(path).to!string, paths);
}

bool parseDmdConfImports(R)(R confPath, scope const(char)[] confDirPath, out string[] paths)
{
	enum Region
	{
		none,
		env32,
		env64
	}

	Region match, current;

	foreach (line; io.File(confPath).byLine)
	{
		line = line.strip;
		if (!line.length)
			continue;

		if (line.sicmp("[Environment32]") == 0)
			current = Region.env32;
		else if (line.sicmp("[Environment64]") == 0)
			current = Region.env64;
		else if (line.startsWith("DFLAGS=") && current >= match)
		{
			version (Windows)
				paths = parseDflagsImports(line["DFLAGS=".length .. $].stripLeft, confDirPath, true);
			else
				paths = parseDflagsImports(line["DFLAGS=".length .. $]
						.stripLeft, confDirPath, false);
			match = current;
		}
	}

	return match != Region.none || paths.length > 0;
}

bool parseLdcConfImports(string confPath, scope const(char)[] binDirPath, out string[] paths)
{
	import external.ldc.config;

	auto ret = appender!(string[]);

	binDirPath = binDirPath.replace('\\', '/');

	void handleSwitch(string value)
	{
		if (value.startsWith("-I"))
			ret ~= value[2 .. $];
	}

	void parseSection(GroupSetting section)
	{
		foreach (c; section.children)
		{
			if (c.type == Setting.Type.array
					&& (c.name == "switches" || c.name == "post-switches"))
			{
				if (auto input = cast(ArraySetting) c)
				{
					foreach (sw; input.vals)
						handleSwitch(sw.replace("%%ldcbinarypath%%", binDirPath));
				}
			}
		}
	}

	foreach (s; parseConfigFile(confPath))
	{
		if (s.type == Setting.Type.group && s.name == "default")
		{
			parseSection(cast(GroupSetting) s);
		}
	}

	paths = ret.data;
	return ret.data.length > 0;
}

deprecated string[] parseDflagsImports(scope const(char)[] options, bool windows)
{
	return parseDflagsImports(options, null, windows);
}

string[] parseDflagsImports(scope const(char)[] options, scope const(char)[] cwd, bool windows)
{
	auto ret = appender!(string[]);
	size_t i = options.indexOf("-I");
	while (i != cast(size_t)-1)
	{
		if (i == 0 || options[i - 1] == '"' || options[i - 1] == '\'' || options[i - 1] == ' ')
		{
			dchar quote = i == 0 ? ' ' : options[i - 1];
			i += "-I".length;
			ret.put(parseArgumentWord(options, quote, i, windows).replace("%@P%", cwd));
		}
		else
			i += "-I".length;

		i = options.indexOf("-I", i);
	}
	return ret.data;
}

private string parseArgumentWord(const scope char[] data, dchar quote, ref size_t i, bool windows)
{
	bool allowEscapes = quote != '\'';
	bool inEscape;
	bool ending = quote == ' ';
	auto part = appender!string;
	while (i < data.length)
	{
		auto c = decode!(UseReplacementDchar.yes)(data, i);
		if (inEscape)
		{
			part.put(c);
			inEscape = false;
		}
		else if (ending)
		{
			// -I"abc"def
			// or
			// -I'abc'\''def'
			if (c.isWhite)
				break;
			else if (c == '\\' && !windows)
				inEscape = true;
			else if (c == '\'')
			{
				quote = c;
				allowEscapes = false;
				ending = false;
			}
			else if (c == '"')
			{
				quote = c;
				allowEscapes = true;
				ending = false;
			}
			else
				part.put(c);
		}
		else
		{
			if (c == quote)
				ending = true;
			else if (c == '\\' && allowEscapes && !windows)
				inEscape = true;
			else
				part.put(c);
		}
	}
	return part.data;
}

unittest
{
	void test(string input, string[] expect)
	{
		auto actual = parseDflagsImports(input, false);
		assert(actual == expect, actual.to!string ~ " != " ~ expect.to!string);
	}

	test(`a`, []);
	test(`-I`, [``]);
	test(`-Iabc`, [`abc`]);
	test(`-Iab\\cd -Ief`, [`ab\cd`, `ef`]);
	test(`-Iab\ cd -Ief`, [`ab cd`, `ef`]);
	test(`-I/usr/include/dmd/phobos -I/usr/include/dmd/druntime/import -L-L/usr/lib/x86_64-linux-gnu -L--export-dynamic -fPIC`,
			[`/usr/include/dmd/phobos`, `/usr/include/dmd/druntime/import`]);
	test(`-I/usr/include/dmd/phobos -L-L/usr/lib/x86_64-linux-gnu -I/usr/include/dmd/druntime/import -L--export-dynamic -fPIC`,
			[`/usr/include/dmd/phobos`, `/usr/include/dmd/druntime/import`]);
}
