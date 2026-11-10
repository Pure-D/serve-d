import std.algorithm;
import std.conv;
import std.file;
import std.stdio;
import std.string;
import std.process;

import workspaced.api;
import workspaced.coms;

int main(string[] args)
{
	string dir = getcwd;
	scope backend = new WorkspaceD();
	auto instance = backend.addInstance(dir);
	backend.register!FSWorkspaceComponent;
	backend.register!DCDComponent(false);
	backend.register!DCDExtComponent;

	version (Windows)
	{
		if (exists("dcd-client.exe"))
			backend.globalConfiguration.set("dcd", "clientPath", "dcd-client.exe");

		if (exists("dcd-server.exe"))
			backend.globalConfiguration.set("dcd", "serverPath", "dcd-server.exe");
	}
	else
	{
		if (exists("dcd-client"))
			backend.globalConfiguration.set("dcd", "clientPath", "dcd-client");

		if (exists("dcd-server"))
			backend.globalConfiguration.set("dcd", "serverPath", "dcd-server");
	}

	bool verbose = args.length > 1 && (args[1] == "-v" || args[1] == "--v" || args[1] == "--verbose");

	assert(backend.attachSilent(instance, "dcd"), "failed to attach DCD, is it not installed correctly?");

	auto fsworkspace = backend.get!FSWorkspaceComponent(dir);
	auto dcd = backend.get!DCDComponent(dir);
	auto dcdext = backend.get!DCDExtComponent(dir);

	fsworkspace.addImports(["source"]);

	auto port = dcd.findAndSelectPort(cast(ushort) 9166).getBlocking;
	instance.config.set("dcd", "port", cast(int) port);

	dcd.setupServer([], true);
	scope (exit)
	{
		dcd.stopServerSync();
		backend.shutdown();
	}

	stderr.writeln("DCD client version: ", dcd.clientInstalledVersion);

	int status = 0;

	foreach (test; dirEntries("tests", SpanMode.shallow))
	{
		if (!test.name.endsWith(".d"))
			continue;
		auto expect = test ~ ".expected";
		auto actualFile = test ~ ".actual";
		if (!expect.exists)
		{
			stderr.writeln("Warning: tests/", expect, " does not exist!");
			continue;
		}
		auto source = test.readText;
		auto reader = File(expect).byLine;
		auto writer = File(actualFile, "w");
		auto cmd = reader.front.splitter;
		string code, message;
		bool success;
		if (cmd.front == "implement")
		{
			writer.writeln("# ", reader.front);

			cmd.popFront;
			auto cmdLine = cmd.front;
			code = dcdext.implement(source, cmdLine.parse!uint, false).getBlocking;
			reader.popFront;

			writer.writeln(code);
			writer.writeln();
			writer.writeln();

			if (verbose)
				stderr.writeln(test, ": ", code);

			success = true;
			size_t index;
			foreach (line; reader)
			{
				if (line.startsWith("--- ") || !line.length)
					continue;

				if (line.startsWith("!"))
				{
					if (code.indexOf(line[1 .. $], index) != -1)
					{
						writer.writeln(line, " - FAIL");
						success = false;
						message = "Did not expect to find line " ~ line[1 .. $].idup
							~ " in (after " ~ index.to!string ~ " bytes) code " ~ code[index .. $];
					}
				}
				else if (line.startsWith("#"))
				{
					// count occurences
					line = line[1 .. $];
					char op = line[0];
					if (!op.among!('<', '=', '>'))
						throw new Exception("Malformed count line: " ~ line.idup);
					line = line[1 .. $];
					int expected = line.parse!uint;
					line = line[1 .. $];
					int actual = countText(code[index .. $], line);
					bool match;
					if (op == '<')
						match = actual < expected;
					else if (op == '=')
						match = actual == expected;
					else if (op == '>')
						match = actual > expected;
					else
						assert(false);
					if (!match)
					{
						writer.writeln(line, " - FAIL");
						success = false;
						message = "Expected to find the string '" ~ line.idup ~ "' " ~ op ~ " " ~ expected.to!string
							~ " times but actually found it " ~ actual.to!string
							~ " times (after " ~ index.to!string ~ " bytes) code " ~ code[index .. $];
					}
				}
				else
				{
					bool freeze = false;
					if (line.startsWith("."))
					{
						freeze = true;
						line = line[1 .. $];
					}
					auto pos = code.indexOf(line, index);
					if (pos == -1)
					{
						writer.writeln(line, " - FAIL");
						success = false;
						message = "Could not find " ~ line.idup ~ " in remaining (after "
							~ index.to!string ~ " bytes) code " ~ code[index .. $];
					}
					else if (!freeze)
					{
						index = pos + line.length;
					}
				}
			}
		}
		else if (cmd.front == "failimplement")
		{
			writer.writeln("# ", reader.front);

			cmd.popFront;
			auto cmdLine = cmd.front;
			code = dcdext.implement(source, cmdLine.parse!uint, false).getBlocking;
			if (code.length != 0)
			{
				writer.writeln("unexpected: ", code);
				writer.writeln();
				message = "Code: " ~ code;
				success = false;
			}
			else
			{
				writer.write("ok\n\n");
				success = true;
			}
		}
		else
			throw new Exception("Unknown command in " ~ expect ~ ": " ~ reader.front.idup);

		if (success)
		{
			writer.close();
			std.file.remove(actualFile);
			writeln("Pass ", expect);
		}
		else
		{
			writer.writeln("-----------------\n\nTest failed\n\n-----------------\n\n");
			writer.writeln(message);
			writeln("Expected fail in ", expect, " but it succeeded. ", message);
			status = 1;
		}
	}

	return status;
}

int countText(in char[] text, in char[] search)
{
	int num = 0;
	ptrdiff_t index = text.indexOf(search);
	while (index != -1)
	{
		num++;
		index = text.indexOf(search, index + search.length);
	}
	return num;
}
