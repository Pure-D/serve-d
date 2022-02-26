module workspaced.api;

// debug = Tasks;

import standardpaths;

import std.algorithm : all;
import std.array : array;
import std.conv;
import std.file : exists, thisExePath;
import std.json : JSONType, JSONValue;
import std.path : baseName, chainPath, dirName;
import std.regex : ctRegex, matchFirst;
import std.string : indexOf, indexOfAny, strip;
import std.traits;

public import workspaced.backend;
public import workspaced.future;

version (unittest)
{
	package import std.experimental.logger : trace;
}
else
{
	// dummy
	package void trace(Args...)(lazy Args)
	{
	}
}

///
alias ImportPathProvider = string[] delegate() nothrow;
///
alias IdentifierListProvider = string[] delegate() nothrow;
///
alias BroadcastCallback = void delegate(WorkspaceD, WorkspaceD.Instance, JSONValue);
/// Called when ComponentFactory.create is called and errored (when the .bind call on a component fails)
/// Params:
/// 	instance = the instance for which the component was attempted to initialize (or null for global component registration)
/// 	factory = the factory on which the error occured with
/// 	error = the stacktrace that was catched on the bind call
alias ComponentBindFailCallback = void delegate(WorkspaceD.Instance instance,
		ComponentFactory factory, Exception error);

/// UDA; will never try to call this function from rpc
enum ignoredFunc;

/// Component call
struct ComponentInfoParams
{
	/// Name of the component
	string name;
}

ComponentInfoParams component(string name)
{
	return ComponentInfoParams(name);
}

struct ComponentInfo
{
	ComponentInfoParams params;
	TypeInfo type;

	alias params this;
}

void traceTaskLog(lazy string msg)
{
	import std.stdio : stderr;

	debug (Tasks)
		stderr.writeln(msg);
}

static immutable traceTask = `traceTaskLog("new task in " ~ __PRETTY_FUNCTION__); scope (exit) traceTaskLog(__PRETTY_FUNCTION__ ~ " exited");`;

mixin template DefaultComponentWrapper(bool withDtor = true)
{
	@ignoredFunc
	{
		import std.algorithm : min, max;
		import std.parallelism : TaskPool, Task, task, defaultPoolThreads;

		WorkspaceD workspaced;
		WorkspaceD.Instance refInstance;

		TaskPool _threads;

		static if (withDtor)
		{
			~this()
			{
				shutdown(true);
			}
		}

		TaskPool gthreads()
		{
			return workspaced.gthreads;
		}

		TaskPool threads(int minSize, int maxSize)
		{
			if (!_threads)
				synchronized (this)
					if (!_threads)
					{
						_threads = new TaskPool(max(minSize, min(maxSize, defaultPoolThreads)));
						_threads.isDaemon = true;
					}
			return _threads;
		}

		inout(WorkspaceD.Instance) instance() inout @property
		{
			if (refInstance)
				return refInstance;
			else
				throw new Exception("Attempted to access instance in a global context");
		}

		WorkspaceD.Instance instance(WorkspaceD.Instance instance) @property
		{
			return refInstance = instance;
		}

		string[] importPaths() const @property
		{
			return instance.importPathProvider ? instance.importPathProvider() : [];
		}

		string[] stringImportPaths() const @property
		{
			return instance.stringImportPathProvider ? instance.stringImportPathProvider() : [];
		}

		string[] importFiles() const @property
		{
			return instance.importFilesProvider ? instance.importFilesProvider() : [];
		}

		/// Lists the project defined version identifiers, if provided by any identifier
		string[] projectVersions() const @property
		{
			return instance.projectVersionsProvider ? instance.projectVersionsProvider() : [];
		}

		/// Lists the project defined debug specification identifiers, if provided by any provider 
		string[] debugSpecifications() const @property
		{
			return instance.debugSpecificationsProvider ? instance.debugSpecificationsProvider() : [];
		}

		ref inout(ImportPathProvider) importPathProvider() @property inout
		{
			return instance.importPathProvider;
		}

		ref inout(ImportPathProvider) stringImportPathProvider() @property inout
		{
			return instance.stringImportPathProvider;
		}

		ref inout(ImportPathProvider) importFilesProvider() @property inout
		{
			return instance.importFilesProvider;
		}

		ref inout(IdentifierListProvider) projectVersionsProvider() @property inout
		{
			return instance.projectVersionsProvider;
		}

		ref inout(IdentifierListProvider) debugSpecificationsProvider() @property inout
		{
			return instance.debugSpecificationsProvider;
		}

		ref inout(Configuration) config() @property inout
		{
			if (refInstance)
				return refInstance.config;
			else if (workspaced)
				return workspaced.globalConfiguration;
			else
				assert(false, "Unbound component trying to access config.");
		}

		bool has(T)()
		{
			if (refInstance)
				return refInstance.has!T;
			else if (workspaced)
				return workspaced.has!T;
			else
				assert(false, "Unbound component trying to check for component " ~ T.stringof ~ ".");
		}

		T get(T)()
		{
			if (refInstance)
				return refInstance.get!T;
			else if (workspaced)
				return workspaced.get!T;
			else
				assert(false, "Unbound component trying to get component " ~ T.stringof ~ ".");
		}

		string cwd() @property const
		{
			return instance.cwd;
		}

		override void shutdown(bool dtor = false)
		{
			if (!dtor && _threads)
				_threads.finish();
		}

		override void bind(WorkspaceD workspaced, WorkspaceD.Instance instance)
		{
			this.workspaced = workspaced;
			this.instance = instance;
			static if (__traits(hasMember, typeof(this).init, "load"))
				load();
		}
	}
}

interface ComponentWrapper
{
	void bind(WorkspaceD workspaced, WorkspaceD.Instance instance);
	void shutdown(bool dtor = false);
}

interface ComponentFactory
{
	ComponentWrapper create(WorkspaceD workspaced, WorkspaceD.Instance instance, out Exception error) nothrow;
	ComponentInfo info() @property const nothrow;
}

struct ComponentFactoryInstance
{
	ComponentFactory factory;
	bool autoRegister;
	alias factory this;
}

struct ComponentWrapperInstance
{
	ComponentWrapper wrapper;
	ComponentInfo info;
}

class DefaultComponentFactory(T : ComponentWrapper) : ComponentFactory
{
	ComponentWrapper create(WorkspaceD workspaced, WorkspaceD.Instance instance, out Exception error) nothrow
	{
		auto wrapper = new T();
		try
		{
			wrapper.bind(workspaced, instance);
			return wrapper;
		}
		catch (Exception e)
		{
			error = e;
			return null;
		}
	}

	ComponentInfo info() @property const nothrow
	{
		alias udas = getUDAs!(T, ComponentInfoParams);
		static assert(udas.length == 1, "Can't construct default component factory for "
				~ T.stringof ~ ", expected exactly 1 ComponentInfoParams instance attached to the type");
		return ComponentInfo(udas[0], typeid(T));
	}
}

/// Describes what to insert/replace/delete to do something
struct CodeReplacement
{
	/// Range what to replace. If both indices are the same its inserting.
	size_t[2] range;
	/// Content to replace it with. Empty means remove.
	string content;

	/// Applies this edit to a string.
	string apply(string code)
	{
		size_t min = range[0];
		size_t max = range[1];
		if (min > max)
		{
			min = range[1];
			max = range[0];
		}
		if (min >= code.length)
			return code ~ content;
		if (max >= code.length)
			return code[0 .. min] ~ content;
		return code[0 .. min] ~ content ~ code[max .. $];
	}
}

/// Code replacements mapped to a file
struct FileChanges
{
	/// File path to change.
	string file;
	/// Replacements to apply.
	CodeReplacement[] replacements;
}

package bool getConfigPath(string file, ref string retPath)
{
	foreach (dir; standardPaths(StandardPath.config, "workspace-d"))
	{
		auto path = chainPath(dir, file);
		if (path.exists)
		{
			retPath = path.array;
			return true;
		}
	}
	return false;
}

enum verRegex = ctRegex!`(\d+)\.(\d+)\.(\d+)`;
bool checkVersion(string ver, int[3] target)
{
	auto match = ver.matchFirst(verRegex);
	if (!match)
		return false;
	const major = match[1].to!int;
	const minor = match[2].to!int;
	const patch = match[3].to!int;
	return checkVersion([major, minor, patch], target);
}

bool checkVersion(int[3] ver, int[3] target)
{
	if (ver[0] > target[0])
		return true;
	if (ver[0] == target[0] && ver[1] > target[1])
		return true;
	if (ver[0] == target[0] && ver[1] == target[1] && ver[2] >= target[2])
		return true;
	return false;
}

package string getVersionAndFixPath(ref string execPath)
{
	import std.process;

	try
	{
		return execute([execPath, "--version"]).output.strip.orDubFetchFallback(execPath);
	}
	catch (ProcessException e)
	{
		auto newPath = chainPath(thisExePath.dirName, execPath.baseName);
		if (exists(newPath))
		{
			execPath = newPath.array;
			return execute([execPath, "--version"]).output.strip.orDubFetchFallback(execPath);
		}
		throw new Exception("Failed running program ['"
			~ execPath ~ "' '--version'] and no alternative existed in '"
			~ newPath.array.idup ~ "'.", e);
	}
}

/// Set for some reason when compiling with `dub fetch` / `dub run` or sometimes
/// on self compilation.
/// Known strings: vbin, vdcd, vDCD
package bool isLocallyCompiledDCD(string v)
{
	import std.uni : sicmp;

	return sicmp(v, "vbin") == 0 || sicmp(v, "vdcd") == 0;
}

/// returns the version that is given or the version extracted from dub path if path is a dub path
package string orDubFetchFallback(string v, string path)
{
	if (v.isLocallyCompiledDCD)
	{
		auto dub = path.indexOf(`dub/packages`);
		if (dub == -1)
			dub = path.indexOf(`dub\packages`);

		if (dub != -1)
		{
			dub += `dub/packages/`.length;
			auto end = path.indexOfAny(`\/`, dub);

			if (end != -1)
			{
				path = path[dub .. end];
				auto semver = extractPathSemver(path);
				if (semver.length)
					return semver;
			}
		}
	}
	return v;
}

unittest
{
	assert("vbin".orDubFetchFallback(`/path/to/home/.dub/packages/dcd-0.13.1/dcd/bin/dcd-server`) == "0.13.1");
	assert("vbin".orDubFetchFallback(`/path/to/home/.dub/packages/dcd-0.13.1-beta.4/dcd/bin/dcd-server`) == "0.13.1-beta.4");
	assert("vbin".orDubFetchFallback(`C:\path\to\appdata\dub\packages\dcd-0.13.1\dcd\bin\dcd-server`) == "0.13.1");
	assert("vbin".orDubFetchFallback(`C:\path\to\appdata\dub\packages\dcd-0.13.1-beta.4\dcd\bin\dcd-server`) == "0.13.1-beta.4");
	assert("vbin".orDubFetchFallback(`C:\path\to\appdata\dub\packages\dcd-master\dcd\bin\dcd-server`) == "vbin");
}

/// searches for a semver in the given string starting after a - character,
/// returns everything until the end.
package string extractPathSemver(string s)
{
	import std.ascii;

	foreach (start; 0 .. s.length)
	{
		// states:
		// -1 = error
		// 0 = expect -
		// 1 = expect major
		// 2 = expect major or .
		// 3 = expect minor
		// 4 = expect minor or .
		// 5 = expect patch
		// 6 = expect patch or - or + (valid)
		// 7 = skip (valid)
		int state = 0;
		foreach (i; start .. s.length)
		{
			auto c = s[i];
			switch (state)
			{
			case 0:
				if (c == '-')
					state++;
				else
					state = -1;
				break;
			case 1:
			case 3:
			case 5:
				if (c.isDigit)
					state++;
				else
					state = -1;
				break;
			case 2:
			case 4:
				if (c == '.')
					state++;
				else if (!c.isDigit)
					state = -1;
				break;
			case 6:
				if (c == '+' || c == '-')
					state = 7;
				else if (!c.isDigit)
					state = -1;
				break;
			default:
				break;
			}

			if (state == -1)
				break;
		}

		if (state >= 6)
			return s[start + 1 .. $];
	}

	return null;
}

unittest
{
	assert(extractPathSemver("foo-v1.0.0") is null);
	assert(extractPathSemver("foo-1.0.0") == "1.0.0");
	assert(extractPathSemver("foo-1.0.0-alpha.1-x") == "1.0.0-alpha.1-x");
	assert(extractPathSemver("foo-1.0.x") is null);
	assert(extractPathSemver("foo-x.0.0") is null);
	assert(extractPathSemver("foo-1.x.0") is null);
	assert(extractPathSemver("foo-1x.0.0") is null);
	assert(extractPathSemver("foo-1.0x.0") is null);
	assert(extractPathSemver("foo-1.0.0x") is null);
	assert(extractPathSemver("-1.0.0") == "1.0.0");
}
