import std.stdio;
import std.process;
import std.string;
import std.file;
import std.path;
import std.datetime;
import std.conv;
import std.algorithm;

string tmp;

int proc(string[] args, string cwd)
{
	writeln("$ ", args.join(" "));
	return spawnProcess(args, stdin, stdout, stderr, null, Config.none, cwd).wait != 0;
}

version (Windows) string getLDC()
{
	try
	{
		execute(["ldc2", "--version"]);
		return "ldc2";
	}
	catch (ProcessException)
	{
		try
		{
			execute(["ldc", "--version"]);
			return "ldc";
		}
		catch (ProcessException)
		{
			return "";
		}
	}
}

bool dubInstall(bool isClonedAlready = false, bool fetchMaster = false)(string folder, string git, string[] output,
		string[][] compilation = [["dub", "upgrade"], ["dub", "build", "--build=release"]])
{
	static if (isClonedAlready)
	{
		writeln("Using existing git repository for " ~ folder);
		string cwd = git;
		if (proc(["git", "submodule", "update", "--init", "--recursive"], cwd) != 0)
		{
			writeln("Error while cloning subpackages of " ~ folder ~ ".");
			return false;
		}
	}
	else
	{
		writeln("Cloning " ~ folder ~ " into ", tmp);
		if (proc(["git", "clone", "-q", "--recursive", git, folder], tmp) != 0)
		{
			writeln("Error while cloning " ~ folder ~ ".");
			return false;
		}
		string cwd = buildNormalizedPath(tmp, folder);
		static if (fetchMaster)
		{
			writeln("Using ~master for building.");
		}
		else
		{
			string tag = execute(["git", "describe", "--abbrev=0", "--tags"], null,
					Config.none, size_t.max, cwd).output.strip();
			if (tag.canFind(" "))
			{
				writeln("Invalid tag in git repository.");
				return false;
			}
			writeln("Checking out ", tag);
			if (proc(["git", "checkout", "-q", tag], cwd) != 0)
			{
				writeln("Error while checking out " ~ folder ~ ".");
				return false;
			}
		}
	}
	writeln("Compiling...");
	foreach (args; compilation)
		if (proc(args, cwd) != 0)
		{
			writeln("Error while compiling " ~ folder ~ ".");
			return false;
		}
	foreach (bin; output)
	{
		auto dest = buildNormalizedPath("bin", bin.baseName);
		copy(buildNormalizedPath(cwd, bin), dest);
		version (Posix)
			dest.setAttributes(dest.getAttributes | octal!111);
	}
	writeln("Successfully compiled " ~ folder ~ "!");
	return true;
}

int main(string[] args)
{
	if (!exists("bin"))
		mkdir("bin");
	if (isFile("bin"))
	{
		writeln("Could not initialize, bin is a file!");
		writeln("Please delete bin!");
		return 1;
	}

	tmp = buildNormalizedPath(tempDir, "workspaced-install-" ~ Clock.currStdTime().to!string);
	mkdirRecurse(tmp);

	writeln("Welcome to the workspace-d installation guide.");
	writeln("Make sure, you have dub and git installed.");
	string winCompiler;
	version (Windows)
	{
		writeln();
		writeln("LDC is required on your platform!");
		winCompiler = getLDC();
		if (!winCompiler.length)
		{
			writeln(
					"WARNING: LDC could was not detected. Before submitting an issue, make sure `dub build --compiler=ldc` works!");
			winCompiler = "ldc";
		}
	}
	writeln();
	string workspacedPath = "";
	string selection;
	if (args.length > 1)
	{
		if (args[1].exists && isDir(args[1]))
		{
			workspacedPath = args[1];
			goto SelectComponents;
		}
		else
			selection = args[1];
	}
	else
	{
	SelectComponents:
		writeln("Which optional dependencies do you want to install?");
		writeln("[1] DCD - auto completion");
		writeln("[2] DScanner - code linting");
		writeln("[3] dfmt - code formatting");
		writeln("Enter a comma separated list of numbers");
		write("Selected [all]: ");
		selection = readln();
		if (!selection.strip().length)
			selection = "all";
	}
	string[] coms = selection.split(',');
	bool dcd, dscanner, dfmt;
	foreach (com; coms)
	{
		com = com.strip().toLower();
		if (com == "")
			continue;
		switch (com)
		{
		case "1":
			dcd = true;
			break;
		case "2":
			dscanner = true;
			break;
		case "3":
			dfmt = true;
			break;
		case "all":
			dcd = dscanner = dfmt = true;
			break;
		default:
			writeln("Component out of range, aborting. (", com, ")");
			return 1;
		}
	}
	version (Windows)
	{
		if (workspacedPath.length)
		{
			if (!dubInstall!true("workspace-d", workspacedPath, [".\\workspace-d.exe", ".\\libcurl.dll",
					".\\libeay32.dll", "ssleay32.dll"], [["dub", "upgrade"], ["dub",
					"build", "--compiler=" ~ winCompiler, "--combined", "--build=release"]])) // must be --combined to avoid windows issues
				return 1;
		}
		else if (!dubInstall("workspace-d", "https://github.com/Pure-D/workspace-d.git",
				[".\\workspace-d.exe", ".\\libcurl.dll",
				".\\libeay32.dll", "ssleay32.dll"], [["git", "submodule", "update",
				"--init", "--recursive"], ["dub", "upgrade"],
				["dub", "build", "--compiler=" ~ winCompiler, "--combined", "--build=release"]]))
			return 1;
		if (dcd && !dubInstall!(false, true)("DCD", "https://github.com/dlang-community/DCD.git",
				[".\\dcd-client.exe", ".\\dcd-server.exe"], [["dub", "upgrade"], ["dub", "build", "--build=release",
				"--config=client"], ["dub", "build", "--build=release", "--config=server"]]))
			return 1;
		if (dscanner && !dubInstall("Dscanner", "https://github.com/dlang-community/Dscanner.git",
				[".\\bin\\dscanner.exe"], [["git", "submodule", "update", "--init",
				"--recursive"], ["cmd", "/c", "build.bat"]]))
			return 1;
		if (dfmt && !dubInstall("dfmt", "https://github.com/dlang-community/dfmt.git", [".\\dfmt.exe"]))
			return 1;
	}
	else
	{
		if (workspacedPath.length)
		{
			if (!dubInstall!true("workspace-d", workspacedPath, ["./workspace-d"]))
				return 1;
		}
		else if (!dubInstall("workspace-d",
				"https://github.com/Pure-D/workspace-d.git", ["./workspace-d"]))
			return 1;
		if (dcd && !dubInstall!(false, true)("DCD", "https://github.com/dlang-community/DCD.git",
				["./dcd-client", "./dcd-server"], [["dub", "upgrade"], ["dub", "build", "--build=release",
				"--config=client"], ["dub", "build", "--build=release", "--config=server"]]))
			return 1;
		if (dscanner && !dubInstall("Dscanner", "https://github.com/dlang-community/Dscanner.git",
				["./bin/dscanner"], [["git", "submodule", "update", "--init", "--recursive"], ["make"]]))
			return 1;
		if (dfmt && !dubInstall("dfmt", "https://github.com/dlang-community/dfmt.git", ["./dfmt"]))
			return 1;
	}
	writeln();
	writeln("SUCCESS");
	writeln("Written applications to bin/");
	writeln("Please add them to your PATH or modify your editor config");
	return 0;
}
