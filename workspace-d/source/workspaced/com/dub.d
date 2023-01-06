module workspaced.com.dub;

import core.exception;
import core.sync.mutex;
import core.thread;

import std.algorithm;
import std.array : appender;
import std.conv;
import std.exception;
import std.parallelism;
import std.regex;
import std.stdio;
import std.string;

import workspaced.api;

import dub.description;
import dub.dub;
import dub.package_;
import dub.project;

import dub.compilers.buildsettings;
import dub.compilers.compiler;
import dub.dependency;
import dub.generators.build;
import dub.generators.generator;

import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.inet.url;

import dub.recipe.io;

@component("dub")
class DubComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	enum WarningId
	{
		invalidDefaultConfig,
		unexpectedError,
		failedListingImportPaths
	}

	static void registered()
	{
		setLogLevel(LogLevel.none);
	}

	protected void load()
	{
		if (!refInstance)
			throw new Exception("dub requires to be instanced");

		if (config.get!bool("dub", "registerImportProvider", true))
			importPathProvider = &imports;
		if (config.get!bool("dub", "registerStringImportProvider", true))
			stringImportPathProvider = &stringImports;
		if (config.get!bool("dub", "registerImportFilesProvider", false))
			importFilesProvider = &fileImports;
		if (config.get!bool("dub", "registerProjectVersionsProvider", true))
			projectVersionsProvider = &versions;
		if (config.get!bool("dub", "registerDebugSpecificationsProvider", true))
			debugSpecificationsProvider = &debugVersions;

		try
		{
			start();

			_configuration = _dub.project.getDefaultConfiguration(_platform);
			if (!_dub.project.configurations.canFind(_configuration))
			{
				workspaced.messageHandler.warn(refInstance, "dub",
					cast(int)WarningId.invalidDefaultConfig,
					"Dub Error: No configuration available");
			}
			else
				updateImportPaths(false);
		}
		catch (Exception e)
		{
			if (!_dub || !_dub.project)
				throw e;
			workspaced.messageHandler.warn(refInstance, "dub",
				cast(int)WarningId.unexpectedError,
				"Dub Error (ignored)",
				e.toString);
		}
		/*catch (AssertError e)
		{
			if (!_dub || !_dub.project)
				throw e;
			workspaced.messageHandler.warn(refInstance, "dub",
				cast(int)WarningId.unexpectedError,
				"Dub Error (ignored): " ~ e.toString);
		}*/
	}

	private void start()
	{
		_dubRunning = false;
		_dub = new Dub(instance.cwd, null, SkipPackageSuppliers.none);
		_dub.loadPackage();
		_dub.packageManager.getOrLoadPackage(NativePath(instance.cwd));
		_dub.project.validate();

		// mark all packages as optional so we don't crash
		int missingPackages;
		auto optionalified = optionalifyPackages;
		foreach (ref pkg; _dub.project.getTopologicalPackageList())
		{
			optionalifyRecipe(pkg);
			foreach (dep; pkg.getAllDependencies()
				.filter!(a => optionalified.canFind(a.name)))
			{
				auto d = _dub.project.getDependency(dep.name, true);
				if (!d)
					missingPackages++;
				else
					optionalifyRecipe(d);
			}
		}

		if (!_compilerBinaryName.length)
			_compilerBinaryName = _dub.defaultCompiler;
		setCompiler(_compilerBinaryName);

		_settingsTemplate = cast() _dub.project.rootPackage.getBuildSettings();

		if (missingPackages > 0)
		{
			upgrade(false);
			optionalifyPackages();
		}

		_dubRunning = true;
	}

	private string[] optionalifyPackages()
	{
		bool[Package] visited;
		string[] optionalified;
		foreach (pkg; _dub.project.dependencies)
			optionalified ~= optionalifyRecipe(cast() pkg);
		return optionalified;
	}

	private string[] optionalifyRecipe(Package pkg)
	{
		string[] optionalified;
		foreach (key, ref value; pkg.recipe.buildSettings.dependencies)
		{
			if (!value.optional)
			{
				value.optional = true;
				value.default_ = true;
				optionalified ~= key;
			}
		}
		foreach (ref config; pkg.recipe.configurations)
			foreach (key, ref value; config.buildSettings.dependencies)
			{
				if (!value.optional)
				{
					value.optional = true;
					value.default_ = true;
					optionalified ~= key;
				}
			}
		return optionalified;
	}

	private void restart()
	{
		_dub.destroy();
		_dubRunning = false;
		start();
	}

	bool isRunning()
	{
		return _dub !is null
			&& _dub.project !is null
			&& _dub.project.rootPackage !is null
			&& _dubRunning;
	}

	/// Reloads the dub.json or dub.sdl file from the cwd
	/// Returns: `false` if there are no import paths available
	Future!bool update()
	{
		restart();
		mixin(gthreadsAsyncProxy!`updateImportPaths(false)`);
	}

	bool updateImportPaths(bool restartDub = true)
	{
		validateConfiguration();

		if (restartDub)
			restart();

		GeneratorSettings settings;
		settings.platform = _platform;
		settings.config = _configuration;
		settings.buildType = _buildType;
		settings.compiler = _compiler;
		settings.buildSettings = _settings;
		settings.buildSettings.addOptions(BuildOption.syntaxOnly);
		settings.combined = true;
		settings.run = false;

		try
		{
			auto paths = _dub.project.listBuildSettings(settings, [
					"import-paths", "string-import-paths", "source-files", "versions", "debug-versions"
					], ListBuildSettingsFormat.listNul);
			_importPaths = paths[0].split('\0');
			_stringImportPaths = paths[1].split('\0');
			_importFiles = paths[2].split('\0');
			_versions = paths[3].split('\0');
			_debugVersions = paths[4].split('\0');
			return _importPaths.length > 0 || _importFiles.length > 0;
		}
		catch (Exception e)
		{
			workspaced.messageHandler.error(refInstance, "dub",
				cast(int)WarningId.failedListingImportPaths,
				"Error while listing import paths",
				e.toString);
			_importPaths = [];
			_stringImportPaths = [];
			return false;
		}
	}

	/// Calls `dub upgrade`
	void upgrade(bool save = true)
	{
		if (save)
			_dub.upgrade(UpgradeOptions.select | UpgradeOptions.upgrade);
		else
			_dub.upgrade(UpgradeOptions.noSaveSelections);
	}

	/// Throws if configuration is invalid, otherwise does nothing.
	void validateConfiguration() const
	{
		if (!_dub.project.configurations.canFind(_configuration))
			throw new Exception("Cannot use dub with invalid configuration");
	}

	/// Throws if configuration is invalid or targetType is none or source library, otherwise does nothing.
	void validateBuildConfiguration()
	{
		validateConfiguration();

		if (_settings.targetType == TargetType.none)
			throw new Exception("Cannot build with dub with targetType == none");
		if (_settings.targetType == TargetType.sourceLibrary)
			throw new Exception("Cannot build with dub with targetType == sourceLibrary");
	}

	/// Lists all dependencies. This will go through all dependencies and contain the dependencies of dependencies. You need to create a tree structure from this yourself.
	/// Returns: `[{dependencies: string[string], ver: string, name: string}]`
	auto dependencies() @property const
	{
		validateConfiguration();

		return listDependencies(_dub.project);
	}

	/// Lists dependencies of the root package. This can be used as a base to create a tree structure.
	string[] rootDependencies() @property const
	{
		validateConfiguration();

		return listDependencies(_dub.project.rootPackage);
	}

	/// Returns the path to the root package recipe (dub.json/dub.sdl)
	///
	/// Note that this can be empty if the package is not in the local file system.
	string recipePath() @property
	{
		return _dub.project.rootPackage.recipePath.toString;
	}

	/// Re-parses the package recipe on the file system and returns if the syntax is valid.
	/// Returns: empty string/null if no error occured, error message if an error occured.
	string validateRecipeSyntaxOnFileSystem()
	{
		auto p = recipePath;
		if (!p.length)
			return "Package is not in local file system";

		try
		{
			readPackageRecipe(p);
			return null;
		}
		catch (Exception e)
		{
			return e.msg;
		}
	}

	/// Lists all import paths
	string[] imports() @property nothrow
	{
		return _importPaths;
	}

	/// Lists all string import paths
	string[] stringImports() @property nothrow
	{
		return _stringImportPaths;
	}

	/// Lists all import paths to files
	string[] fileImports() @property nothrow
	{
		return _importFiles;
	}

	/// Lists the currently defined versions
	string[] versions() @property nothrow
	{
		return _versions;
	}

	/// Lists the currently defined debug versions (debug specifications)
	string[] debugVersions() @property nothrow
	{
		return _debugVersions;
	}

	/// Lists all configurations defined in the package description
	string[] configurations() @property
	{
		return _dub.project.configurations;
	}

	PackageBuildSettings rootPackageBuildSettings() @property
	{
		auto pkg = _dub.project.rootPackage;
		BuildSettings settings = pkg.getBuildSettings(_platform, _configuration);
		return PackageBuildSettings(settings,
				pkg.path.toString,
				pkg.name,
				_dub.project.rootPackage.recipePath.toNativeString());
	}

	/// Lists all build types defined in the package description AND the predefined ones from dub ("plain", "debug", "release", "release-debug", "release-nobounds", "unittest", "docs", "ddox", "profile", "profile-gc", "cov", "unittest-cov")
	string[] buildTypes() const @property
	{
		string[] types = [
			"plain", "debug", "release", "release-debug", "release-nobounds",
			"unittest", "docs", "ddox", "profile", "profile-gc", "cov", "unittest-cov"
		];
		foreach (type, info; _dub.project.rootPackage.recipe.buildTypes)
			types ~= type;
		return types;
	}

	/// Gets the current selected configuration
	string configuration() const @property
	{
		return _configuration;
	}

	/// Selects a new configuration and updates the import paths accordingly
	/// Returns: `false` if there are no import paths in the new configuration
	bool setConfiguration(string configuration)
	{
		if (!_dub.project.configurations.canFind(configuration))
			return false;
		_configuration = configuration;
		_settingsTemplate = cast() _dub.project.rootPackage.getBuildSettings(configuration);
		return updateImportPaths(false);
	}

	/// List all possible arch types for current set compiler
	string[] archTypes() const @property
	{
		auto types = appender!(string[]);
		types ~= ["x86_64", "x86"];

		string compilerName = _compiler.name;

		if (compilerName == "dmd")
		{
			// https://github.com/dlang/dub/blob/master/source/dub/compilers/dmd.d#L110
			version (Windows)
			{
				types ~= ["x86_omf", "x86_mscoff"];
			}
		}
		else if (compilerName == "gdc")
		{
			// https://github.com/dlang/dub/blob/master/source/dub/compilers/gdc.d#L69
			types ~= ["arm", "arm_thumb"];
		}
		else if (compilerName == "ldc")
		{
			// https://github.com/dlang/dub/blob/master/source/dub/compilers/ldc.d#L80
			types ~= ["aarch64", "powerpc64"];
		}

		return types.data;
	}

	/// ditto
	ArchType[] extendedArchTypes() const @property
	{
		auto types = appender!(ArchType[]);
		string compilerName = _compiler.name;

		if (compilerName == "dmd")
		{
			types ~= [
				ArchType("", "(compiler default)"),
				ArchType("x86_64"),
				ArchType("x86")
			];
			// https://github.com/dlang/dub/blob/master/source/dub/compilers/dmd.d#L110
			version (Windows)
			{
				types ~= [ArchType("x86_omf"), ArchType("x86_mscoff")];
			}
		}
		else if (compilerName == "gdc")
		{
			// https://github.com/dlang/dub/blob/master/source/dub/compilers/gdc.d#L69
			types ~= [
				ArchType("", "(compiler default)"),
				ArchType("x86_64", "64-bit (current platform)"),
				ArchType("x86", "32-bit (current platform)"),
				ArchType("arm"),
				ArchType("arm_thumb")
			];
		}
		else if (compilerName == "ldc")
		{
			types ~= [
				ArchType("", "(compiler default)"),
				ArchType("x86_64"),
				ArchType("x86")
			];
			// https://github.com/dlang/dub/blob/master/source/dub/compilers/ldc.d#L80
			types ~= [
				ArchType("aarch64"),
				ArchType("powerpc64"),
				ArchType("wasm32-unknown-unknown-wasm", "WebAssembly")
			];
		}

		return types.data;
	}

	/// Returns the current selected arch type, or empty string for compiler default.
	string archType() const @property
	{
		return _archType;
	}

	/// Selects a new arch type and updates the import paths accordingly
	/// Returns: `false` if there are no import paths in the new arch type
	bool setArchType(string type)
	{
		try
		{
			_platform = _compiler.determinePlatform(_settings, _compilerBinaryName, type);
		}
		catch (Exception e)
		{
			return false;
		}

		_archType = type;
		return updateImportPaths(false);
	}

	/// Returns the current selected build type
	string buildType() const @property
	{
		return _buildType;
	}

	/// Selects a new build type and updates the import paths accordingly
	/// Returns: `false` if there are no import paths in the new build type
	bool setBuildType(string type)
	{
		if (buildTypes.canFind(type))
		{
			_buildType = type;
			return updateImportPaths(false);
		}
		else
		{
			return false;
		}
	}

	/// Returns the current selected compiler
	string compiler() const @property
	{
		return _compilerBinaryName;
	}

	/// Selects a new compiler for building
	/// Returns: `false` if the compiler does not exist or some setting is
	/// invalid.
	///
	/// If the current architecture does not exist with this compiler it will be
	/// reset to the compiler default. (empty string)
	bool setCompiler(string compiler)
	{
		try
		{
			_compilerBinaryName = compiler;
			_compiler = getCompiler(compiler); // make sure it gets a valid compiler
		}
		catch (Exception e)
		{
			return false;
		}

		try
		{
			_platform = _compiler.determinePlatform(_settings, _compilerBinaryName, _archType);
		}
		catch (UnsupportedArchitectureException e)
		{
			if (_archType.length)
			{
				_archType = "";
				return setCompiler(compiler);
			}
			return false;
		}

		_settingsTemplate.getPlatformSettings(_settings, _platform,
			_dub.project.rootPackage.path);
		return _compiler !is null;
	}

	/// Returns the project name
	string name() const @property
	{
		return _dub.projectName;
	}

	/// Returns the project path
	auto path() const @property
	{
		return _dub.projectPath;
	}

	/// Returns whether there is a target set to build. If this is false then build will throw an exception.
	deprecated("catch an exception on build instead")
	bool canBuild() const @property
	{
		if (_settings.targetType == TargetType.none || _settings.targetType == TargetType.sourceLibrary
				|| !_dub.project.configurations.canFind(_configuration))
			return false;
		return true;
	}

	/// Asynchroniously builds the project WITHOUT OUTPUT. This is intended for linting code and showing build errors quickly inside the IDE.
	Future!(BuildIssue[]) build()
	{
		import std.process : thisProcessID;
		import std.file : tempDir;
		import std.random : uniform;

		validateBuildConfiguration();

		// copy to this thread
		auto compiler = _compiler;
		auto buildPlatform = _platform;

		GeneratorSettings settings;
		settings.platform = buildPlatform;
		settings.config = _configuration;
		settings.buildType = _buildType;
		settings.compiler = compiler;
		settings.buildSettings = _dub.project.rootPackage.getBuildSettings(buildPlatform, _configuration);

		string cwd = instance.cwd;

		auto ret = new typeof(return);
		new Thread({
			try
			{
				auto issues = appender!(BuildIssue[]);

				settings.compileCallback = (status, output) {
					trace(status, " ", output);
					string[] lines = output.splitLines;
					foreach (line; lines)
					{
						auto match = line.matchFirst(errorFormat);
						if (match)
						{
							issues ~= BuildIssue(match[2].to!int, match[3].toOr!int(0),
								match[1], match[4].to!ErrorType, match[5]);
						}
						else
						{
							auto contMatch = line.matchFirst(errorFormatCont);
							if (issues.data.length && contMatch)
							{
								issues ~= BuildIssue(contMatch[2].to!int,
									contMatch[3].toOr!int(1), contMatch[1],
									issues.data[$ - 1].type, contMatch[4], true);
							}
							else if (line.canFind("is deprecated"))
							{
								auto deprMatch = line.matchFirst(deprecationFormat);
								if (deprMatch)
								{
									issues ~= BuildIssue(deprMatch[2].to!int, deprMatch[3].toOr!int(1),
										deprMatch[1], ErrorType.Deprecation,
										deprMatch[4] ~ " is deprecated" ~ deprMatch[5]);
								}
							}
						}
					}
				};
				try
				{
					import workspaced.dub.lintgenerator : DubLintGenerator;
					import std.file : chdir;

					// TODO: make DUB not use getcwd, but use the dub.cwd
					chdir(cwd);

					new DubLintGenerator(_dub.project).generate(settings);
				}
				catch (CompilerInvocationException e)
				{
					// ignore compiler exiting with error
				}
				ret.finish(issues.data);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		}).start();
		return ret;
	}

	/// Converts the root package recipe to another format.
	/// Params:
	///     format = either "json" or "sdl".
	string convertRecipe(string format)
	{
		import dub.recipe.io : serializePackageRecipe;
		import std.array : appender;

		auto dst = appender!string;
		serializePackageRecipe(dst, _dub.project.rootPackage.rawRecipe, "dub." ~ format);
		return dst.data;
	}

	/// Tries to find a suitable code byte range where a given dub build issue
	/// applies to.
	/// Returns: `[pos, pos]` if not found, otherwise range in bytes which might
	/// not contain the position at all.
	int[2] resolveDiagnosticRange(scope const(char)[] code, int position,
			scope const(char)[] diagnostic)
	{
		import dparse.lexer : getTokensForParser, LexerConfig;
		import dparse.parser : parseModule;
		import dparse.rollback_allocator : RollbackAllocator;
		import workspaced.dub.diagnostics : resolveDubDiagnosticRange;

		LexerConfig config;
		RollbackAllocator rba;
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto parsed = parseModule(tokens, "equal_finder.d", &rba);

		return resolveDubDiagnosticRange(code, tokens, parsed, position, diagnostic);
	}

private:
	Dub _dub;
	bool _dubRunning = false;
	string _configuration;
	string _archType = "";
	string _buildType = "debug";
	string _compilerBinaryName;
	Compiler _compiler;
	BuildSettingsTemplate _settingsTemplate;
	BuildSettings _settings;
	BuildPlatform _platform;
	string[] _importPaths, _stringImportPaths, _importFiles, _versions, _debugVersions;
}

///
enum ErrorType : ubyte
{
	///
	Error = 0,
	///
	Warning = 1,
	///
	Deprecation = 2
}

/// Returned by build
struct BuildIssue
{
	///
	int line, column;
	///
	string file;
	/// The error type (Error/Warning/Deprecation) outputted by dmd or inherited from the last error if this is additional information of the last issue. (indicated by cont)
	ErrorType type;
	///
	string text;
	/// true if this is additional error information for the last error.
	bool cont;
}

private enum ignoreCopy; // UDA for ignored values on copy
/// returned by rootPackageBuildSettings
struct PackageBuildSettings
{
	/// construct from dub build settings
	this(BuildSettings dubBuildSettings, string packagePath, string packageName, string recipePath)
	{
		foreach (i, ref val; this.tupleof)
		{
			alias attr = __traits(getAttributes, this.tupleof[i]);
			static if (attr.length == 0 || !__traits(isSame, attr[0], ignoreCopy))
			{
				enum name = __traits(identifier, this.tupleof[i]);
				val = __traits(getMember, dubBuildSettings, name);
			}
		}
		this.packagePath = packagePath;
		this.packageName = packageName;
		this.recipePath = recipePath;

		if (!targetName.length)
			targetName = packageName;

		version (Windows)
			targetName ~= ".exe";

		this.targetType = dubBuildSettings.targetType.to!string;
		foreach (enumMember; __traits(allMembers, BuildOption))
		{
			enum value = __traits(getMember, BuildOption, enumMember);
			if (value != 0 && dubBuildSettings.options.opDispatch!enumMember)
				this.buildOptions ~= enumMember;
		}
		foreach (enumMember; __traits(allMembers, BuildRequirement))
		{
			enum value = __traits(getMember, BuildRequirement, enumMember);
			if (value != 0 && dubBuildSettings.requirements.opDispatch!enumMember)
				this.buildRequirements ~= enumMember;
		}
	}

	@ignoreCopy
	string packagePath;
	@ignoreCopy
	string packageName;
	@ignoreCopy
	string recipePath;

	string targetPath; /// same as dub BuildSettings
	string targetName; /// same as dub BuildSettings
	string workingDirectory; /// same as dub BuildSettings
	string mainSourceFile; /// same as dub BuildSettings
	string[] dflags; /// same as dub BuildSettings
	string[] lflags; /// same as dub BuildSettings
	string[] libs; /// same as dub BuildSettings
	string[] linkerFiles; /// same as dub BuildSettings
	string[] sourceFiles; /// same as dub BuildSettings
	string[] copyFiles; /// same as dub BuildSettings
	string[] extraDependencyFiles; /// same as dub BuildSettings
	string[] versions; /// same as dub BuildSettings
	string[] debugVersions; /// same as dub BuildSettings
	string[] versionFilters; /// same as dub BuildSettings
	string[] debugVersionFilters; /// same as dub BuildSettings
	string[] importPaths; /// same as dub BuildSettings
	string[] stringImportPaths; /// same as dub BuildSettings
	string[] importFiles; /// same as dub BuildSettings
	string[] stringImportFiles; /// same as dub BuildSettings
	string[] preGenerateCommands; /// same as dub BuildSettings
	string[] postGenerateCommands; /// same as dub BuildSettings
	string[] preBuildCommands; /// same as dub BuildSettings
	string[] postBuildCommands; /// same as dub BuildSettings
	string[] preRunCommands; /// same as dub BuildSettings
	string[] postRunCommands; /// same as dub BuildSettings

	@ignoreCopy:

	string targetType; /// same as dub BuildSettings
	string[] buildOptions; /// same as dub BuildSettings
	string[] buildRequirements; /// same as dub BuildSettings
}

private:

T toOr(T)(string s, T defaultValue)
{
	if (!s || !s.length)
		return defaultValue;
	return s.to!T;
}

enum harmlessExceptionFormat = ctRegex!(`failed with exit code`, "g");
enum errorFormat = ctRegex!(`(.*?)\((\d+)(?:,(\d+))?\): (Deprecation|Warning|Error): (.*)`, "gi");
enum errorFormatCont = ctRegex!(`(.*?)\((\d+)(?:,(\d+))?\):[ ]{6,}(.*)`, "g");
enum deprecationFormat = ctRegex!(
			`(.*?)\((\d+)(?:,(\d+))?\): (.*?) is deprecated(.*)`, "g");

struct DubPackageInfo
{
	string[string] dependencies;
	string ver;
	string name;
	string path;
	string description;
	string homepage;
	const(string)[] authors;
	string copyright;
	string license;
	DubPackageInfo[] subPackages;

	void fill(in PackageRecipe recipe)
	{
		description = recipe.description;
		homepage = recipe.homepage;
		authors = recipe.authors;
		copyright = recipe.copyright;
		license = recipe.license;

		foreach (subpackage; recipe.subPackages)
		{
			DubPackageInfo info;
			info.ver = subpackage.recipe.version_;
			info.name = subpackage.recipe.name;
			info.path = subpackage.path;
			info.fill(subpackage.recipe);
		}
	}
}

DubPackageInfo getInfo(in Package dep)
{
	DubPackageInfo info;
	info.name = dep.name;
	info.ver = dep.version_.toString;
	info.path = dep.path.toString;
	info.fill(dep.recipe);
	foreach (subDep; dep.getAllDependencies())
	{
		info.dependencies[subDep.name] = subDep.spec.toString;
	}
	return info;
}

auto listDependencies(scope const Project project)
{
	auto deps = project.dependencies;
	DubPackageInfo[] dependencies;
	if (deps is null)
		return dependencies;
	foreach (dep; deps)
	{
		dependencies ~= getInfo(dep);
	}
	return dependencies;
}

string[] listDependencies(scope const Package pkg)
{
	auto deps = pkg.getAllDependencies();
	string[] dependencies;
	if (deps is null)
		return dependencies;
	foreach (dep; deps)
		dependencies ~= dep.name;
	return dependencies;
}

///
struct ArchType
{
	/// Value to pass into other calls
	string value;
	/// UI label override or null if none
	string label;
}
