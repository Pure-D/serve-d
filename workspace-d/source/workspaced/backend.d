module workspaced.backend;

import dparse.lexer : StringCache;

import std.algorithm : canFind, map, max, min, remove, startsWith;
import std.array : array;
import std.conv;
import std.file : exists, mkdir, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.parallelism : defaultPoolThreads, TaskPool;
import std.path : buildNormalizedPath, buildPath;
import std.range : chain;
import std.sumtype : match, SumType, This;
import std.traits : getUDAs, isSomeString;

import workspaced.api;

struct Configuration
{
	alias ValueT = SumType!(typeof(null), string, bool, long, double, This[], This[string]);

	private static ValueT toValueT(T)(T value)
	{
		static if (is(immutable T == immutable ValueT))
			return value;
		else static if (is(T : U[], U))
		{
			ValueT[] ret = new ValueT[value.length];
			foreach (i, v; value)
				ret[i] = toValueT(v);
			return ValueT(ret);
		}
		else static if (is(T : U[string], U))
		{
			ValueT[string] ret;
			foreach (k, v; value)
				ret[k] = toValueT(v);
			return ValueT(ret);
		}
		else
		{
			return ValueT(value);
		}
	}

	static T toType(T)(ValueT value)
	{
		return value.match!(
			(typeof(null) n) {
				if (false) return T.init; // make return type T

				static if (__traits(compiles, T.init is null) && T.init is null)
					return T.init;
				else
					throw new Exception("Cannot convert null to type " ~ T.stringof);
			},
			(ValueT[] v) {
				if (false) return T.init; // make return type T

				static if (is(typeof(T.init[0])))
				{
					T ret;
					ret.reserve(v.length);
					foreach (i; v)
						ret ~= toType!(typeof(T.init[0]))(i);
					return ret;
				}
				else
					throw new Exception("Cannot convert array to type " ~ T.stringof);
			},
			(ValueT[string] m) {
				if (false) return T.init; // make return type T

				static if (is(typeof(T.init[""])))
				{
					T ret;
					foreach (k, v; m)
						ret[k] = toType!(typeof(ret[k]))(v);
					return ret;
				}
				else
					throw new Exception("Cannot convert map to type " ~ T.stringof);
			},
			(s) {
				if (false) return T.init; // make return type T

				static if (is(T : typeof(s)))
					return cast(T) s;
				else static if (__traits(compiles, s.to!T))
					return s.to!T;
				else
					throw new Exception("Cannot convert " ~ typeof(s).stringof
						~ " to type " ~ T.stringof);
			}
		);
	}

	static struct Section
	{
		ValueT[string] values;
	}

	/// base configuration formatted as {[component]:{key:value pairs}}
	Section[string] base;

	bool get(string component, string key, out ValueT val) const
	{
		auto com = component in base;
		if (!com)
			return false;
		auto v = key in com.values;
		if (!v)
			return false;
		val = *v;
		return true;
	}

	T get(T)(string component, string key, T defaultValue = T.init) inout
	{
		ValueT ret;
		if (!get(component, key, ret))
			return defaultValue;
		return toType!T(ret);
	}

	bool set(T)(string component, string key, T value)
	{
		if (auto com = component in base)
		{
			com.values[key] = toValueT(value);
		}
		else
		{
			ValueT[string] val;
			val[key] = toValueT(value);
			base[component] = Section(val);
		}
		return true;
	}

	/// Same as init but might make nicer code.
	enum none = Configuration.init;

	/// Loads unset keys from global, keeps existing keys
	void loadBase(Configuration global)
	{
		if (base is null)
			base = global.base.dup;
		else
		{
			foreach (component, config; global.base)
			{
				auto existing = component in base;
				if (!existing)
					base[component] = config.deepCopy;
				else
				{
					foreach (key, value; config.values)
					{
						auto existingValue = key in existing.values;
						if (!existingValue)
							existing.values[key] = value.deepCopy;
					}
				}
			}
		}
	}
}

private T deepCopy(T)(T value)
{
	static if (is(T : typeof(null)) || __traits(isPOD, T))
		return value;
	else static if (is(T == Configuration.ValueT))
	{
		return value.match!(v => deepCopy(v));
	}
	else static if (is(T : Configuration.Section))
	{
		return Configuration.Section(deepCopy(value.values));
	}
	else static if (is(T : Configuration.ValueT[]))
	{
		auto copy = new Configuration.ValueT[value.length];
		foreach (i, ref v; copy)
			v = deepCopy(value[i]);
		return copy;
	}
	else static if (is(T : Configuration.ValueT[string]))
	{
		Configuration.ValueT[string] copy;
		foreach (k, v; value)
			copy[k] = deepCopy(v);
		return copy;
	}
	else
		return value.dup;
}

/// WorkspaceD instance holding plugins.
class WorkspaceD
{
	static class Instance
	{
		string cwd;
		ComponentWrapperInstance[] instanceComponents;
		Configuration config;

		string[] importPaths() const @property nothrow
		{
			return importPathProvider ? importPathProvider() : [];
		}

		string[] stringImportPaths() const @property nothrow
		{
			return stringImportPathProvider ? stringImportPathProvider() : [];
		}

		string[] importFiles() const @property nothrow
		{
			return importFilesProvider ? importFilesProvider() : [];
		}

		void shutdown(bool dtor = false)
		{
			foreach (ref com; instanceComponents)
				com.wrapper.shutdown(dtor);
			instanceComponents = null;
		}

		ImportPathProvider importPathProvider;
		ImportPathProvider stringImportPathProvider;
		ImportPathProvider importFilesProvider;
		IdentifierListProvider projectVersionsProvider;
		IdentifierListProvider debugSpecificationsProvider;

		/* virtual */
		void onBeforeAccessComponent(ComponentInfo) const
		{
		}

		/* virtual */
		bool checkHasComponent(ComponentInfo info) const nothrow
		{
			foreach (com; instanceComponents)
				if (com.info.name == info.name)
					return true;
			return false;
		}

		inout(T) get(T)() inout
		{
			auto info = getUDAs!(T, ComponentInfoParams)[0];
			onBeforeAccessComponent(ComponentInfo(info, typeid(T)));
			foreach (com; instanceComponents)
				if (com.info.name == info.name)
					return cast(inout T) com.wrapper;
			throw new Exception(
					"Attempted to get unknown instance component " ~ T.stringof
					~ " in instance cwd:" ~ cwd);
		}

		bool has(T)() const nothrow
		{
			auto info = getUDAs!(T, ComponentInfoParams)[0];
			return checkHasComponent(ComponentInfo(info, typeid(T)));
		}

		/// Shuts down an attached component and removes it from this component
		/// list. If you plan to remove all components, call $(LREF shutdown)
		/// instead.
		/// Returns: `true` if the component was loaded and is now unloaded and
		///          removed or `false` if the component wasn't found.
		bool detach(T)()
		{
			auto info = getUDAs!(T, ComponentInfoParams)[0];
			return detach(ComponentInfo(info, typeid(T)));
		}

		/// ditto
		bool detach(ComponentInfo info)
		{
			foreach (i, com; instanceComponents)
				if (com.info.name == info.name)
				{
					instanceComponents = instanceComponents.remove(i);
					com.wrapper.shutdown(false);
					return true;
				}
			return false;
		}

		/// Loads a registered component which didn't have auto register on just for this instance.
		/// Returns: false instead of using the onBindFail callback on failure.
		/// Throws: Exception if component was not registered in workspaced.
		bool attach(T)(WorkspaceD workspaced)
		{
			string info = getUDAs!(T, ComponentInfoParams)[0];
			return attach(workspaced, ComponentInfo(info, typeid(T)));
		}

		/// ditto
		bool attach(WorkspaceD workspaced, ComponentInfo info)
		{
			foreach (factory; workspaced.components)
			{
				if (factory.info.name == info.name)
				{
					Exception e;
					auto inst = factory.create(workspaced, this, e);
					if (inst)
					{
						attachComponent(ComponentWrapperInstance(inst, info));
						return true;
					}
					else
						return false;
				}
			}
			throw new Exception("Component not found");
		}

		void attachComponent(ComponentWrapperInstance component)
		{
			instanceComponents ~= component;
		}
	}

	import std.typecons : BlackHole;
	/// Called from components to push messages to the app.
	IMessageHandler messageHandler = new BlackHole!IMessageHandler;
	/// Called when ComponentFactory.create is called and errored (when the .bind call on a component fails)
	/// See_Also: $(LREF ComponentBindFailCallback)
	ComponentBindFailCallback onBindFail;

	Instance[] instances;
	/// Base global configuration for new instances, does not modify existing ones.
	Configuration globalConfiguration;
	ComponentWrapperInstance[] globalComponents;
	ComponentFactoryInstance[] components;
	StringCache stringCache;

	TaskPool _gthreads;

	this()
	{
		stringCache = StringCache(StringCache.defaultBucketCount * 4);
	}

	~this()
	{
		shutdown(true);
	}

	void shutdown(bool dtor = false)
	{
		foreach (ref instance; instances)
			instance.shutdown(dtor);
		instances = null;
		foreach (ref com; globalComponents)
			com.wrapper.shutdown(dtor);
		globalComponents = null;
		components = null;
		if (_gthreads)
			_gthreads.finish(true);
		_gthreads = null;
	}

	Instance getInstance(string cwd) nothrow
	{
		cwd = buildNormalizedPath(cwd);
		foreach (instance; instances)
			if (instance.cwd == cwd)
				return instance;
		return null;
	}

	Instance getBestInstanceByDependency(WithComponent)(string file) nothrow
	{
		Instance best;
		size_t bestLength;
		foreach (instance; instances)
		{
			foreach (folder; chain(instance.importPaths, instance.importFiles,
					instance.stringImportPaths))
			{
				if (folder.length > bestLength && file.startsWith(folder)
						&& instance.has!WithComponent)
				{
					best = instance;
					bestLength = folder.length;
				}
			}
		}
		return best;
	}

	Instance getBestInstanceByDependency(string file) nothrow
	{
		Instance best;
		size_t bestLength;
		foreach (instance; instances)
		{
			foreach (folder; chain(instance.importPaths, instance.importFiles,
					instance.stringImportPaths))
			{
				if (folder.length > bestLength && file.startsWith(folder))
				{
					best = instance;
					bestLength = folder.length;
				}
			}
		}
		return best;
	}

	Instance getBestInstance(WithComponent)(string file, bool fallback = true) nothrow
	{
		file = buildNormalizedPath(file);
		Instance ret = null;
		size_t best;
		foreach (instance; instances)
		{
			if (instance.cwd.length > best && file.startsWith(instance.cwd)
					&& instance.has!WithComponent)
			{
				ret = instance;
				best = instance.cwd.length;
			}
		}
		if (!ret && fallback)
		{
			ret = getBestInstanceByDependency!WithComponent(file);
			if (ret)
				return ret;
			foreach (instance; instances)
				if (instance.has!WithComponent)
					return instance;
		}
		return ret;
	}

	Instance getBestInstance(string file, bool fallback = true) nothrow
	{
		file = buildNormalizedPath(file);
		Instance ret = null;
		size_t best;
		foreach (instance; instances)
		{
			if (instance.cwd.length > best && file.startsWith(instance.cwd))
			{
				ret = instance;
				best = instance.cwd.length;
			}
		}
		if (!ret && fallback && instances.length)
		{
			ret = getBestInstanceByDependency(file);
			if (!ret)
				ret = instances[0];
		}
		return ret;
	}

	/* virtual */
	void onBeforeAccessGlobalComponent(ComponentInfo) const
	{
	}

	/* virtual */
	bool checkHasGlobalComponent(ComponentInfo info) const
	{
		foreach (com; globalComponents)
			if (com.info.name == info.name)
				return true;
		return false;
	}

	T get(T)()
	{
		auto info = getUDAs!(T, ComponentInfoParams)[0];
		onBeforeAccessGlobalComponent(ComponentInfo(info, typeid(T)));
		foreach (com; globalComponents)
			if (com.info.name == info.name)
				return cast(T) com.wrapper;
		throw new Exception("Attempted to get unknown global component " ~ T.stringof);
	}

	bool has(T)()
	{
		auto info = getUDAs!(T, ComponentInfoParams)[0];
		return checkHasGlobalComponent(ComponentInfo(info, typeid(T)));
	}

	T get(T)(string cwd)
	{
		if (!cwd.length)
			return this.get!T;
		auto inst = getInstance(cwd);
		if (inst is null)
			throw new Exception("cwd '" ~ cwd ~ "' not found");
		return inst.get!T;
	}

	bool has(T)(string cwd)
	{
		auto inst = getInstance(cwd);
		if (inst is null)
			return false;
		return inst.has!T;
	}

	T best(T)(string file, bool fallback = true)
	{
		if (!file.length)
			return this.get!T;
		auto inst = getBestInstance!T(file);
		if (inst is null)
			throw new Exception("cwd for '" ~ file ~ "' not found");
		return inst.get!T;
	}

	bool hasBest(T)(string cwd, bool fallback = true)
	{
		auto inst = getBestInstance!T(cwd);
		if (inst is null)
			return false;
		return inst.has!T;
	}

	void onRegisterComponent(ref ComponentFactory factory, bool autoRegister)
	{
		components ~= ComponentFactoryInstance(factory, autoRegister);
		auto info = factory.info;
		Exception error;
		auto glob = factory.create(this, null, error);
		if (glob)
			globalComponents ~= ComponentWrapperInstance(glob, info);
		else if (onBindFail)
			onBindFail(null, factory, error);

		if (autoRegister)
			foreach (ref instance; instances)
			{
				auto inst = factory.create(this, instance, error);
				if (inst)
					instance.attachComponent(ComponentWrapperInstance(inst, info));
				else if (onBindFail)
					onBindFail(instance, factory, error);
			}
	}

	ComponentFactory register(T)(bool autoRegister = true)
	{
		ComponentFactory factory;
		static foreach (attr; __traits(getAttributes, T))
			static if (is(attr == class) && is(attr : ComponentFactory))
				factory = new attr;
		if (factory is null)
			factory = new DefaultComponentFactory!T;

		onRegisterComponent(factory, autoRegister);

		static if (__traits(compiles, T.registered(this)))
			T.registered(this);
		else static if (__traits(compiles, T.registered()))
			T.registered();
		return factory;
	}

	protected Instance createInstance(string cwd, Configuration config)
	{
		auto inst = new Instance();
		inst.cwd = cwd;
		inst.config = config;
		return inst;
	}

	protected void preloadComponents(Instance inst, string[] preloadComponents)
	{
		foreach (name; preloadComponents)
		{
			foreach (factory; components)
			{
				if (!factory.autoRegister && factory.info.name == name)
				{
					Exception error;
					auto wrap = factory.create(this, inst, error);
					if (wrap)
						inst.attachComponent(ComponentWrapperInstance(wrap, factory.info));
					else if (onBindFail)
						onBindFail(inst, factory, error);
					break;
				}
			}
		}
	}

	protected void autoRegisterComponents(Instance inst)
	{
		foreach (factory; components)
		{
			if (factory.autoRegister)
			{
				Exception error;
				auto wrap = factory.create(this, inst, error);
				if (wrap)
					inst.attachComponent(ComponentWrapperInstance(wrap, factory.info));
				else if (onBindFail)
					onBindFail(inst, factory, error);
			}
		}
	}

	/// Creates a new workspace with the given cwd with optional config overrides and preload components for non-autoRegister components.
	/// Throws: Exception if normalized cwd already exists as instance.
	Instance addInstance(string cwd, Configuration configOverrides = Configuration.none,
			string[] preloadComponents = [])
	{
		cwd = buildNormalizedPath(cwd);
		if (instances.canFind!(a => a.cwd == cwd))
			throw new Exception("Instance with cwd '" ~ cwd ~ "' already exists!");
		configOverrides.loadBase(globalConfiguration);
		auto inst = createInstance(cwd, configOverrides);
		this.preloadComponents(inst, preloadComponents);
		this.autoRegisterComponents(inst);
		instances ~= inst;
		return inst;
	}

	bool removeInstance(string cwd)
	{
		cwd = buildNormalizedPath(cwd);
		foreach (i, instance; instances)
			if (instance.cwd == cwd)
			{
				foreach (com; instance.instanceComponents)
					destroy(com.wrapper);
				destroy(instance);
				instances = instances.remove(i);
				return true;
			}
		return false;
	}

	deprecated("Use overload taking an out Exception error or attachSilent instead")
	final bool attach(Instance instance, string component)
	{
		return attachSilent(instance, component);
	}

	final bool attachSilent(Instance instance, string component)
	{
		Exception error;
		return attach(instance, component, error);
	}

	bool attach(Instance instance, string component, out Exception error)
	{
		foreach (factory; components)
		{
			if (factory.info.name == component)
			{
				auto wrap = factory.create(this, instance, error);
				if (wrap)
				{
					instance.attachComponent(ComponentWrapperInstance(wrap, factory.info));
					return true;
				}
				else
					return false;
			}
		}
		return false;
	}

	TaskPool gthreads()
	{
		if (!_gthreads)
			synchronized (this)
				if (!_gthreads)
				{
					_gthreads = new TaskPool(max(2, min(6, defaultPoolThreads)));
					_gthreads.isDaemon = true;
				}
		return _gthreads;
	}
}

version (unittest)
{
	struct TestingWorkspace
	{
		string directory;

		@disable this(this);

		this(string path)
		{
			if (path.exists)
				throw new Exception("Path already exists");
			directory = path;
			mkdir(path);
		}

		~this()
		{
			rmdirRecurse(directory);
		}

		string getPath(string path)
		{
			return buildPath(directory, path);
		}

		void createDir(string dir)
		{
			mkdirRecurse(getPath(dir));
		}

		void writeFile(string path, string content)
		{
			write(getPath(path), content);
		}
	}

	TestingWorkspace makeTemporaryTestingWorkspace()
	{
		import std.random;

		return TestingWorkspace(buildPath(tempDir,
				"workspace-d-test-" ~ uniform(0, long.max).to!string(36)));
	}
}
