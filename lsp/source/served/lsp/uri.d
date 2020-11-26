module served.lsp.uri;

import served.lsp.protocol;
import std.path;
import std.string;

DocumentUri uriFromFile(string file)
{
	import std.uri : encodeComponent;

	if (!isAbsolute(file))
		throw new Exception("Tried to pass relative path '" ~ file ~ "' to uriFromFile");
	file = file.buildNormalizedPath.replace("\\", "/");
	if (file.length == 0)
		return "";
	if (file[0] != '/')
		file = '/' ~ file; // always triple slash at start but never quad slash
	if (file.length >= 2 && file[0 .. 2] == "//") // Shares (\\share\bob) are different somehow
		file = file[2 .. $];
	return "file://" ~ file.encodeComponent.replace("%2F", "/");
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
	return scheme ~ "://" ~ (authority.length ? authority : "") ~ (path.length ? path
			: "/") ~ (query.length ? "?" ~ query : "") ~ (fragment.length ? "#" ~ fragment : "");
}
