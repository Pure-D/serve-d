module served.lsp.uri;

import served.lsp.protocol;
import std.algorithm;
import std.conv;
import std.path;
import std.string;

version (unittest)
private void assertEquals(T)(T a, T b)
{
	assert(a == b, "'" ~ a.to!string ~ "' != '" ~ b.to!string ~ "'");
}

DocumentUri uriFromFile(scope const(char)[] file)
{
	import std.uri : encodeComponent;

	if ((!isAbsolute(file) && !file.startsWith("/"))
		|| !file.length)
		throw new Exception(text("Tried to pass relative path '", file, "' to uriFromFile"));
	file = file.buildNormalizedPath.replace("\\", "/");
	assert(file.length);
	if (file.ptr[0] != '/')
		file = '/' ~ file; // always triple slash at start but never quad slash
	if (file.length >= 2 && file[0 .. 2] == "//") // Shares (\\share\bob) are different somehow
		file = file[2 .. $];
	return text("file://", file.encodeComponent.replace("%2F", "/"));
}

unittest
{
	import std.exception;

	version (Windows)
	{

	}
	else
	{
		assertEquals(uriFromFile(`/home/foo/bar.d`), `file:///home/foo/bar.d`);
		assertThrown(uriFromFile(`../bar.d`));
		assertThrown(uriFromFile(``));
		assertEquals(uriFromFile(`/../../bar.d`), `file:///bar.d`);

	}
}

string uriToFile(DocumentUri uri)
{
	import std.uri : decodeComponent;
	import std.string : startsWith;

	if (uri.startsWith("file://"))
	{
		string ret = uri["file://".length .. $].decodeComponent;
		if (ret.length >= 3 && ret[0] == '/' && ret[2] == ':') // file:///x: windows path
			return ret[1 .. $].replace("/", "\\");
		else if (ret.length >= 1 && ret[0] != '/') // file://share windows path
			return "\\\\" ~ ret.replace("/", "\\");
		return ret;
	}
	else
		return null;
}

@system unittest
{
	void testUri(string a, string b)
	{
		assertEquals(a.uriFromFile, b);
		assertEquals(a, b.uriToFile);
		assertEquals(a.uriFromFile.uriToFile, a);
		assertEquals(uriBuildNormalized("file:///unrelated/path.txt", a), b);
	}

	version (Windows)
	{
		// taken from vscode-uri
		testUri(`c:\test with %\path`, `file:///c%3A/test%20with%20%25/path`);
		testUri(`c:\test with %25\path`, `file:///c%3A/test%20with%20%2525/path`);
		testUri(`c:\test with %25\c#code`, `file:///c%3A/test%20with%20%2525/c%23code`);
		testUri(`\\shäres\path\c#\plugin.json`, `file://sh%C3%A4res/path/c%23/plugin.json`);
		testUri(`\\localhost\c$\GitDevelopment\express`, `file://localhost/c%24/GitDevelopment/express`);
	}
	else version (Posix)
	{
		testUri(`/home/pi/.bashrc`, `file:///home/pi/.bashrc`);
		testUri(`/home/pi/Development Projects/D-code`, `file:///home/pi/Development%20Projects/D-code`);
	}

	assertEquals("file:///c:/foo/bar.d".uriToFile, `c:\foo\bar.d`);
	assertEquals("file://share/foo/bar.d".uriToFile, `\\share\foo\bar.d`);

	assert(!uriToFile("/foo").length);
	assert(!uriToFile("http://foo.de/bar.d").length);
}

///
DocumentUri uri(string scheme, string authority, string path, string query, string fragment)
{
	import std.array;
	import std.uri : encodeComponent;

	// from https://github.com/microsoft/vscode-uri/blob/96acdc0be5f9d5f2640e1c1f6733bbf51ec95177/src/uri.ts#L589
	auto res = appender!string;
	if (scheme.length) {
		res ~= scheme;
		res ~= ':';
	}
	if (authority.length || scheme == "file") {
		res ~= "//";
	}
	if (authority.length) {
		auto idx = authority.indexOf('@');
		if (idx != -1) {
			// <user>@<auth>
			const userinfo = authority[0 .. idx];
			authority = authority[idx + 1 .. $];
			idx = userinfo.indexOf(':');
			if (idx == -1) {
				res ~= userinfo.encodeComponent;
			} else {
				// <user>:<pass>@<auth>
				res ~= userinfo[0 .. idx].encodeComponent;
				res ~= ':';
				res ~= userinfo[idx + 1 .. $].encodeComponent;
			}
			res ~= '@';
		}
		authority = authority.toLower();
		idx = authority.indexOf(':');
		if (idx == -1) {
			res ~= authority.encodeComponent;
		} else {
			// <auth>:<port>
			res ~= authority[0 .. idx].encodeComponent;
			res ~= authority[idx .. $];
		}
	}
	if (path.length) {
		// lower-case windows drive letters in /C:/fff or C:/fff
		if (path.length >= 3 && path[0] == '/' && path[2] == ':') {
			const code = path[1];
			if (code >= 'A' && code <= 'Z') {
				path = ['/', cast(char)(code + 32), ':'].idup ~ path[3 .. $];
			}
		} else if (path.length >= 2 && path[1] == ':') {
			const code = path[0];
			if (code >= 'A' && code <= 'Z') {
				path = [cast(char)(code + 32), ':'].idup ~ path[2 .. $];
			}
		}
		// encode the rest of the path
		res ~= path.encodeComponent.replace("%2F", "/");
	}
	if (query.length) {
		res ~= '?';
		res ~= query.encodeComponent;
	}
	if (fragment.length) {
		res ~= '#';
		res ~= fragment.encodeComponent;
	}
	return res.data;
}

///
unittest
{
	assert(uri("file", null, "/home/foo/bar.d", null, null) == "file:///home/foo/bar.d");
	assert(uri("file", null, "/home/foo bar.d", null, null) == "file:///home/foo%20bar.d");
}

inout(char)[] uriDirName(scope return inout(char)[] uri)
{
	auto slash = uri.lastIndexOf('/');
	if (slash == 0)
		return uri[0 .. 1];
	else if (slash == -1)
		return null;

	if (uri[slash - 1] == '/')
	{
		if (slash == uri.length - 1)
			return uri;
		else
			return uri[0 .. slash + 1];
	}
	return uri[0 .. slash];
}

///
unittest
{
	assert("/".uriDirName == "/");
	assert("a/".uriDirName == "a");
	assert("a".uriDirName == "");
	assert("/a".uriDirName == "/");
	assert("file:///".uriDirName == "file:///");
	assert("file:///a".uriDirName == "file:///");
	assert("file:///a/".uriDirName == "file:///a");
	assert("file:///foo/bar/".uriDirName == "file:///foo/bar");
	assert("file:///foo/bar".uriDirName == "file:///foo");
	assert("file:///foo/bar".uriDirName.uriDirName == "file:///");
	assert("file:///foo/bar".uriDirName.uriDirName.uriDirName == "file:///");
}

/// Appends the path to the uri, potentially replacing the whole thing if the
/// path is absolute. Cleans `./` and `../` sequences using `uriNormalize`.
DocumentUri uriBuildNormalized(DocumentUri uri, scope const(char)[] path)
{
	if (isAbsolute(path))
		return uriFromFile(path).uriNormalize;

	path = path.replace("\\", "/");

	if (path.startsWith("/"))
	{
		auto scheme = uri.indexOf("://");
		if (scheme == -1)
			return uriFromFile(path).uriNormalize;
		else
			return text(uri[0 .. scheme + 3], path).uriNormalize;
	}
	else
	{
		return text(uri, "/", path).uriNormalize;
	}
}

///
unittest
{
	assertEquals(uriBuildNormalized("file:///foo/bar", "baz"), "file:///foo/bar/baz");
	assertEquals(uriBuildNormalized("file:///foo/bar", "../baz"), "file:///foo/baz");
	version (Windows)
		assertEquals(uriBuildNormalized("file:///foo/bar", `c:\home\baz`), "file:///c%3A/home/baz");
	else
		assertEquals(uriBuildNormalized("file:///foo/bar", "/homr/../home/baz"), "file:///home/baz");
	assertEquals(uriBuildNormalized("file:///foo/bar", "../../../../baz"), "file:///../../baz");
}

/// Cleans `./` and `../` from the URI.
inout(char)[] uriNormalize(scope return inout(char)[] uri)
{
	ptrdiff_t index;
	while (true)
	{
		auto sameDir = uri.indexOf("./", index);
		if (sameDir == -1)
			break;
		if (sameDir == 0)
			uri = uri.ptr[2 .. uri.length];
		else if (sameDir >= 2 && uri.ptr[sameDir - 1] == '.' && uri.ptr[sameDir - 2] == '/') // /../
		{
			auto pre = uri.ptr[0 .. sameDir - 1];
			if (pre.endsWith("//", "../") || pre == "/")
			{
				index = sameDir + 2;
			}
			else
			{
				auto dirName = pre.ptr[0 .. pre.length - 1].uriDirName;
				if (dirName.endsWith("/") || !dirName.length)
					uri = dirName ~ uri.ptr[sameDir + 2 .. uri.length];
				else
					uri = dirName ~ uri.ptr[sameDir + 1 .. uri.length];
			}
		}
		else if (sameDir == 1 && uri.ptr[0] == '.') // ^../
			index = sameDir + 2;
		else if (uri.ptr[sameDir - 1] == '/') // /./
			uri = uri.ptr[0 .. sameDir] ~ uri.ptr[sameDir + 2 .. uri.length];
		else // a./b
			index = sameDir + 2;
	}

	return uri;
}

unittest
{
	assertEquals(uriNormalize(`b/../a.d`), `a.d`);
	assertEquals(uriNormalize(`b/../../a.d`), `../a.d`);
	
	foreach (prefix; ["file:///", "file://", "", "/", "//"])
	{
		assertEquals(uriNormalize(prefix ~ `foo/bar/./a.d`), prefix ~ `foo/bar/a.d`);
		assertEquals(uriNormalize(prefix ~ `foo/bar/../a.d`), prefix ~ `foo/a.d`);
		assertEquals(uriNormalize(prefix ~ `foo/bar/./.././a.d`), prefix ~ `foo/a.d`);
		assertEquals(uriNormalize(prefix ~ `../a.d`), prefix ~ `../a.d`);
		assertEquals(uriNormalize(prefix ~ `b/../../../../d/../../../a.d`), prefix ~ `../../../../../a.d`);
		assertEquals(uriNormalize(prefix ~ `./a.d`), prefix ~ `a.d`);
		assertEquals(uriNormalize(prefix ~ `a./a.d`), prefix ~ `a./a.d`);
		assertEquals(uriNormalize(prefix ~ `.a/a.d`), prefix ~ `.a/a.d`);
		assertEquals(uriNormalize(prefix ~ `foo/a./../a.d`), prefix ~ `foo/a.d`);
		assertEquals(uriNormalize(prefix ~ `a./../a.d`), prefix ~ `a.d`);
	}
}
