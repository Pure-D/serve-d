import std.stdio : writeln;
import std.file;
import std.path;
import std.conv;
import std.process;

static import std.stdio;

import workspaced.info;

void main()
{
	if (!exists("debs"))
		mkdir("debs");
	auto pkgVersion = Version[0].to!string ~ "." ~ Version[1].to!string ~ "-" ~ Version[2].to!string;
	string pkgPath = "workspace-d_" ~ pkgVersion;
	if (exists("debs/" ~ pkgPath))
	{
		writeln("Package already exists, returning");
		return;
	}
	mkdir("debs/" ~ pkgPath);
	mkdir("debs/" ~ pkgPath ~ "/DEBIAN");
	write("debs/" ~ pkgPath ~ "/DEBIAN/control", `Package: workspace-d
Version: ` ~ pkgVersion ~ `
Section: base
Priority: optional
Architecture: amd64
Maintainer: WebFreak001 <workspace-d@webfreak.org>
Description: Wraps dcd, dfmt and dscanner to one unified environment managed by dub
`);
	mkdir("debs/" ~ pkgPath ~ "/usr");
	mkdir("debs/" ~ pkgPath ~ "/usr/local");
	mkdir("debs/" ~ pkgPath ~ "/usr/local/bin");
	writeln("Building workspace-d");
	spawnProcess(["dub", "build", "--compiler=ldc", "--build=release"]).wait;
	writeln("Compressing regular linux package");
	spawnProcess(["tar", "cfJ",
			"workspace-d_" ~ Version[0].to!string ~ "." ~ Version[1].to!string ~ "."
			~ Version[2].to!string ~ "-linux-x86_64.tar.xz", "workspace-d"]).wait;
	rename("workspace-d", "debs/" ~ pkgPath ~ "/usr/local/bin/workspace-d");
	writeln("Generating package in debs/ folder");
	spawnProcess(["dpkg-deb", "--build", pkgPath], std.stdio.stdin,
			std.stdio.stdout, std.stdio.stderr, null, Config.none, buildPath(getcwd, "debs")).wait;
	writeln("Done");
}
