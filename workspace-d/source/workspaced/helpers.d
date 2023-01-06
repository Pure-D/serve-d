module workspaced.helpers;

import std.algorithm;
import std.ascii;
import std.datetime.systime;
import std.file;
import std.string;

version (Posix)
	import core.sys.posix.sys.stat : stat, stat_t;
else version (Windows)
	import core.sys.windows.windef;

string determineIndentation(scope const(char)[] code) @safe
{
	const(char)[] indent = null;
	foreach (line; code.lineSplitter)
	{
		if (line.strip.length == 0)
			continue;
		(() @trusted {
			// trusted to avoid 'scope variable `line` assigned to `indent` with longer lifetime'
			// lifetime is fine, because line has lifetime of code (is just a slice of code)
			indent = line[0 .. $ - line.stripLeft.length];
		})();
	}
	return indent.idup;
}

int stripLineEndingLength(scope const(char)[] code) @safe @nogc
{
	switch (code.length)
	{
		case 0:
			return 0;
		case 1:
			return code[0] == '\r' || code[0] == '\n' ? 1 : 0;
		default:
			if (code[$ - 2 .. $] == "\r\n")
				return 2;
			else if (code[$ - 1] == '\r' || code[$ - 1] == '\n')
				return 1;
			else
				return 0;
	}
}

bool isIdentifierChar(dchar c) @safe @nogc
{
	return c.isAlphaNum || c == '_';
}

ptrdiff_t indexOfKeyword(scope const(char)[] code, string keyword, ptrdiff_t start = 0) @safe @nogc
{
	ptrdiff_t index = start;
	while (true)
	{
		index = code.indexOf(keyword, index);
		if (index == -1)
			break;

		if ((index > 0 && code[index - 1].isIdentifierChar)
				|| (index + keyword.length < code.length && code[index + keyword.length].isIdentifierChar))
		{
			index++;
			continue;
		}
		else
			break;
	}
	return index;
}

bool endsWithKeyword(scope const(char)[] code, string keyword) @safe @nogc
{
	return code == keyword || (code.endsWith(keyword) && code[$ - 1 - keyword.length]
			.isIdentifierChar);
}

inout(char)[] getIdentifierAt(scope return inout(char)[] code, size_t index) @safe
{
	while (index > 0 && code[index - 1].isIdentifierChar)
		index--;

	size_t end = index;
	while (end < code.length && !code[end].isDIdentifierSeparatingChar)
		end++;

	return code[index .. end];
}

deprecated("use isDIdentifierSeparatingChar instead")
alias isIdentifierSeparatingChar = isDIdentifierSeparatingChar;

bool isDIdentifierSeparatingChar(dchar c) @safe @nogc
{
	return c < 48 || (c > 57 && c < 65) || c == '[' || c == '\\' || c == ']'
		|| c == '`' || (c > 122 && c < 128) || c == '\u2028' || c == '\u2029'; // line separators
}

bool isValidDIdentifier(scope const(char)[] s)
{
	import std.algorithm : any;
	import std.ascii : isDigit;

	return s.length && !s[0].isDigit && !s.any!isDIdentifierSeparatingChar;
}

version (unittest)
{
	import std.json;

	/// Iterates over all files in the given folder, reads them as D files until
	/// a __EOF__ token is encountered, then parses the following lines in this
	/// format per file:
	/// - If the line is empty or starts with `//` ignore it
	/// - If the line starts with `:` it's a variable assignment in form `:variable=JSON`
	/// - Otherwise it's a tab separated line like `1	2	3`
	/// Finally, it's tested that at least one test has been tested.
	void runTestDataFileTests(string dir,
		void delegate() onFileStart,
		void delegate(string code, string variable, JSONValue value) setVariable,
		void delegate(string code, string[] parts, string line) onTestLine,
		void delegate(string code) onFileFinished,
		string __file = __FILE__,
		size_t __line = __LINE__)
	{
		import core.exception;
		import std.algorithm;
		import std.array;
		import std.conv;
		import std.file;
		import std.stdio;

		int noTested = 0;
		foreach (testFile; dirEntries(dir, SpanMode.shallow))
		{
			int lineNo = 0;
			try
			{
				auto testCode = appender!string;
				bool inCode = true;
				if (onFileStart)
					onFileStart();
				foreach (line; File(testFile, "r").byLine)
				{
					lineNo++;
					if (line == "__EOF__")
					{
						inCode = false;
						continue;
					}

					if (inCode)
					{
						testCode ~= line;
						testCode ~= '\n'; // normalize CRLF to LF
					}
					else if (!line.length || line.startsWith("//"))
					{
						continue;
					}
					else if (line[0] == ':')
					{
						auto variable = line[1 .. $].idup.findSplit("=");
						if (setVariable)
							setVariable(testCode.data, variable[0], parseJSON(variable[2]));
					}
					else
					{
						if (onTestLine)
						{
							string lineDup = line.idup;
							onTestLine(testCode.data, lineDup.split("\t"), lineDup);
						}
					}
				}

				if (onFileFinished)
					onFileFinished(testCode.data);
				noTested++;
			}
			catch (AssertError e)
			{
				e.file = __file;
				e.line = __line;
				e.msg = "in " ~ testFile ~ "(" ~ lineNo.to!string ~ "): " ~ e.msg;
				throw e;
			}
		}

		assert(noTested > 0);
	}
}

/// same as getAttributes without throwing
/// Returns: true if exists, false otherwise
bool statFile(R)(R name, uint* attributes, SysTime* writeTime, ulong* size)
{
	version (Windows)
	{
		import std.internal.cstring : tempCStringW;
		import core.sys.windows.winnt : INVALID_FILE_ATTRIBUTES;
		import core.sys.windows.winbase : GetFileAttributesExW, WIN32_FILE_ATTRIBUTE_DATA, GET_FILEEX_INFO_LEVELS;

		auto namez = tempCStringW(name);
		WIN32_FILE_ATTRIBUTE_DATA fad;
		static bool trustedGetFileAttributesW(const(wchar)* namez, WIN32_FILE_ATTRIBUTE_DATA* fad) @trusted
		{
			return GetFileAttributesExW(namez, GET_FILEEX_INFO_LEVELS.GetFileExInfoStandard, fad);
		}
		if (!trustedGetFileAttributesW(namez, &fad))
			return false;

		if (attributes)
			*attributes = fad.dwFileAttributes;
		if (writeTime)
			*writeTime = FILETIMEToSysTime(&fad.ftLastWriteTime);
		if (size)
			*size = makeUlong(fad.nFileSizeLow, fad.nFileSizeHigh);
		return true;
	}
	else version (Posix)
	{
		import std.internal.cstring : tempCString;

		auto namez = tempCString(name);
		static auto trustedStat(const(char)* namez, out stat_t statbuf) @trusted
		{
			return stat(namez, &statbuf);
		}

		stat_t statbuf;
		if (trustedStat(namez, statbuf) != 0)
			return false;

		if (attributes)
			*attributes = statbuf.st_mode;
		if (writeTime)
			*writeTime = statTimeToStdTime!'m'(statbuf);
		if (size)
			*size = statbuf.st_size;
		return true;
	}
	else
	{
		static assert(false, "Unimplemented stat for this platform");
	}
}

bool existsAndIsFile(string file)
{
	uint attributes;
	if (!statFile(file, &attributes, null, null))
		return false;
	return attrIsFile(attributes);
}

bool existsAndIsDir(string file)
{
	uint attributes;
	if (!statFile(file, &attributes, null, null))
		return false;
	return attrIsDir(attributes);
}

// copied from std.file
version (Posix)
private SysTime statTimeToStdTime(char which)(ref const stat_t statbuf)
{
	auto unixTime = mixin(`statbuf.st_` ~ which ~ `time`);
	long stdTime = unixTimeToStdTime(unixTime);

	static if (is(typeof(mixin(`statbuf.st_` ~ which ~ `tim`))))
		stdTime += mixin(`statbuf.st_` ~ which ~ `tim.tv_nsec`) / 100;
	else
	static if (is(typeof(mixin(`statbuf.st_` ~ which ~ `timensec`))))
		stdTime += mixin(`statbuf.st_` ~ which ~ `timensec`) / 100;
	else
	static if (is(typeof(mixin(`statbuf.st_` ~ which ~ `time_nsec`))))
		stdTime += mixin(`statbuf.st_` ~ which ~ `time_nsec`) / 100;
	else
	static if (is(typeof(mixin(`statbuf.__st_` ~ which ~ `timensec`))))
		stdTime += mixin(`statbuf.__st_` ~ which ~ `timensec`) / 100;

	return SysTime(stdTime);
}

version (Windows) private ulong makeUlong(DWORD dwLow, DWORD dwHigh) @safe pure nothrow @nogc
{
	ULARGE_INTEGER li;
	li.LowPart  = dwLow;
	li.HighPart = dwHigh;
	return li.QuadPart;
}

/// Inserts a value into a sorted range. Inserts before equal elements.
/// Returns: the index where the value has been inserted.
size_t insertSorted(alias sort = "a<b", T)(ref T[] arr, T value)
{
	auto v = arr.binarySearch!sort(value);
	if (v < 0)
		v = ~v;
	arr.length++;
	for (ptrdiff_t i = cast(ptrdiff_t) arr.length - 1; i > v; i--)
		move(arr.ptr[i - 1], arr.ptr[i]);
	move(value, arr.ptr[v]);
	return v;
}

/// ditto
size_t insertSortedNoDup(alias sort = "a<b", T)(ref T[] arr, T value)
{
	auto v = ~arr.binarySearch!sort(value);
	if (v < 0)
		return ~v;
	arr.length++;
	for (ptrdiff_t i = cast(ptrdiff_t) arr.length - 1; i > v; i--)
		move(arr.ptr[i - 1], arr.ptr[i]);
	move(value, arr.ptr[v]);
	return v;
}

/// Finds a value in a sorted range and returns its index.
/// Returns: a bitwise invert of the first element bigger than value. Use `~ret` to turn it back.
ptrdiff_t binarySearch(alias sort = "a<b", T)(T[] arr, auto ref T value)
{
	import std.functional;
	import std.range;

	if (arr.length < 6)
	{
		foreach (i; 0 .. arr.length)
		{
			if (binaryFun!sort(value, arr.ptr[i]))
				return ~i;
			else if (binaryFun!sort(arr.ptr[i], value))
			{}
			else
				return i;
		}
		return ~arr.length;
	}
	else
	{
		ptrdiff_t l = 0;
		ptrdiff_t r = arr.length;
		while (l < r)
		{
			ptrdiff_t m = (l + r) / 2;
			if (binaryFun!sort(arr.ptr[m], value))
				l = m + 1;
			else if (binaryFun!sort(value, arr.ptr[m]))
				r = m;
			else
				return m;
		}
		return ~l;
	}
}

unittest
{
	int[] values;
	foreach (i; 0 .. 20)
	{
		values ~= i * 2;
		assert(binarySearch(values, -1) == ~0);
		assert(binarySearch(values, 1) == ~1);
		foreach (j; 0 .. i)
		{
			assert(binarySearch(values, j * 2) == j);
		}
	}
}

unittest
{
	import std.random;

	foreach (i; 0 .. 100)
	{
		int[] values;
		foreach (j; 0 .. 30)
		{
			values.insertSorted(uniform(0, 10000));
			assert(isSorted(values));
		}
	}
}
