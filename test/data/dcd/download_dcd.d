import std.algorithm;
import std.conv;
import std.file;
import std.format;
import std.process;
import std.stdio;
import std.string;

void downloadFile(string path, string url)
{
	import std.net.curl : download;

	if (exists(path))
		return;

	stderr.writeln("Downloading ", url, " to ", path);

	download(url, path);
}

void extractZip(string path)
{
	import std.zip : ZipArchive;

	auto zip = new ZipArchive(read(path));
	foreach (name, am; zip.directory)
	{
		stderr.writeln("Unpacking ", name);
		zip.expand(am);

		if (exists(name))
			remove(name);

		std.file.write(name, am.expandedData);
	}
}

static immutable latestKnownVersion = (){
	import workspaced.com.dcd_version : latestKnownDCDVersion;

	return latestKnownDCDVersion;
}();

void main()
{
	string ver = format!"%(%s.%)"(latestKnownVersion);
	string dcdClient = "dcd-client";
	string dcdServer = "dcd-server";
	version (Windows)
	{
		dcdClient ~= ".exe";
		dcdServer ~= ".exe";
		string zip = "dcd-" ~ ver ~ ".zip";
		string url = format!"https://github.com/dlang-community/DCD/releases/download/v%s/dcd-v%s-windows-x86_64.zip"(ver, ver);
		void extract()
		{
			extractZip(zip);
		}
	}
	else version (linux)
	{
		string zip = "dcd-v" ~ ver ~ "-linux-x86_64.tar.gz";
		string url = format!"https://github.com/dlang-community/DCD/releases/download/v%s/dcd-v%s-linux-x86_64.tar.gz"(ver, ver);
		void extract()
		{
			spawnShell("tar -xzvf " ~ zip ~ " > /dev/null").wait;
		}
	}
	else version (OSX)
	{
		string zip = "dcd-v" ~ ver ~ "-osx-x86_64.tar.gz";
		string url = format!"https://github.com/dlang-community/DCD/releases/download/v%s/dcd-v%s-osx-x86_64.tar.gz"(ver, ver);
		void extract()
		{
			spawnShell("tar -xzvf " ~ zip ~ " > /dev/null").wait;
		}
	}

	if (!exists(zip))
	{
		writeln("Downloading DCD ", ver);
		downloadFile(zip, url);
	}

	try { remove(dcdClient); } catch (FileException) { /* ignore */ }
	try { remove(dcdServer); } catch (FileException) { /* ignore */ }

	extract();
}

