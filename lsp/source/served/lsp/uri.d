module served.lsp.uri;

import served.lsp.protocol;
import std.algorithm;
import std.conv;
import std.path;
import std.string;

DocumentUri uriFromFile(scope const(char)[] file)
{
	import std.uri : encodeComponent;

	if (!isAbsolute(file))
		throw new Exception(text("Tried to pass relative path '", file, "' to uriFromFile"));
	file = file.buildNormalizedPath.replace("\\", "/");
	if (file.length == 0)
		return "";
	if (file[0] != '/')
		file = '/' ~ file; // always triple slash at start but never quad slash
	if (file.length >= 2 && file[0 .. 2] == "//") // Shares (\\share\bob) are different somehow
		file = file[2 .. $];
	return text("file://", file.encodeComponent.replace("%2F", "/"));
}

string uriToFile(DocumentUri uri)
{
	import std.uri : decodeComponent;
	import std.string : startsWith;

	if (uri.startsWith("file://"))
	{
		string ret = uri["file://".length .. $].decodeComponent;
		if (ret.length >= 3 && ret[0] == '/' && ret[2] == ':')
			return ret[1 .. $].replace("/", "\\");
		else if (ret.length >= 1 && ret[0] != '/')
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
		void assertEqual(A, B)(A a, B b)
		{
			import std.conv : to;

			assert(a == b, a.to!string ~ " is not equal to " ~ b.to!string);
		}

		assertEqual(a.uriFromFile, b);
		assertEqual(a, b.uriToFile);
		assertEqual(a.uriFromFile.uriToFile, a);
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
}

DocumentUri uri(string scheme, string authority, string path, string query, string fragment)
{
	return scheme ~ "://"
		~ (authority.length ? authority : "")
		~ (path.length ? path : "/")
		~ (query.length ? "?" ~ query : "")
		~ (fragment.length ? "#" ~ fragment : "");
}

DocumentUri uriDirName(DocumentUri uri)
{
	auto slash = uri.lastIndexOf('/');
	if (slash <= 0)
		return uri;
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
	assert("file:///foo/bar/".uriDirName == "file:///foo/bar");
	assert("file:///foo/bar".uriDirName == "file:///foo");
	assert("file:///foo/bar".uriDirName.uriDirName == "file:///");
}

/// Appends the path to the uri, potentially replacing the whole thing if the
/// path is absolute. Cleans `./` and `../` sequences using `uriNormalize`.
DocumentUri uriBuildNormalized(DocumentUri uri, scope const(char)[] path)
{
	if (isAbsolute(path))
		return uriFromFile(path);

	path = path.replace("\\", "/");

	if (path.startsWith("/"))
	{
		auto scheme = uri.indexOf("://");
		if (scheme == -1)
			return path.idup;
		else
			return text(uri[0 .. scheme + 3], path[1 .. $]);
	}

	while (path.startsWith("../"))
	{
		uri = uri.uriDirName;
		path = path[3 .. $];
	}

	if (path.startsWith("/"))
		path = path[1 .. $];

	return text(uri, "/", path).uriNormalize;
}

///
unittest
{
	assert(uriBuildNormalized("file:///foo/bar", "baz") == "file:///foo/bar/baz");
	assert(uriBuildNormalized("file:///foo/bar", "../baz") == "file:///foo/baz");
	version (Windows)
		assert(uriBuildNormalized("file:///foo/bar", `c:\home\baz`) == "file:///c%3A/home/baz");
	else
		assert(uriBuildNormalized("file:///foo/bar", "/home/baz") == "file:///home/baz");
}

/// Cleans `./` and `../` from the URI
DocumentUri uriNormalize(DocumentUri uri)
{
	while (true)
	{
		auto sameDir = uri.indexOf("./");
		if (sameDir == -1)
			break;
		if (sameDir == 0)
			uri = uri[2 .. $];
		else if (sameDir >= 2 && uri[sameDir - 1] == '.' && uri[sameDir - 2] == '/') // /../
			uri = uri[0 .. sameDir - 1].uriDirName ~ uri[sameDir + 2 .. $];
		else if (uri[sameDir - 1] == '/') // /./
			uri = uri[0 .. sameDir] ~ uri[sameDir + 2 .. $];
		else
			break; // might break on `a./b` here, but better than infinite loop for malformed url
	}

	return uri;
}
