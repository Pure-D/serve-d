/**
	Generator for direct compiler builds.

	Copyright: © 2013-2013 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license.
	Authors: Sönke Ludwig, Jan Jurzitza
*/
module workspaced.dub.lintgenerator;

// TODO: this sucks, this is copy pasted from build.d in dub and only removed binary output here

import dub.compilers.compiler;
import dub.compilers.utils;
import dub.generators.generator;
import dub.internal.utils;
import dub.internal.vibecompat.inet.path;
import dub.package_;
import dub.packagemanager;
import dub.project;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.experimental.logger;
import std.file;
import std.process;
import std.string;

class DubLintGenerator : ProjectGenerator
{
	this(Project project)
	{
		super(project);
	}

	override void generateTargets(GeneratorSettings settings, in TargetInfo[string] targets)
	{
		auto root_ti = targets[m_project.rootPackage.name];

		tracef("Performing \"%s\" build using %s for %-(%s, %).", settings.buildType,
				settings.platform.compilerBinary, settings.platform.architecture);

		auto bs = root_ti.buildSettings.dup;
		performDirectBuild(settings, bs, root_ti.pack, root_ti.config);
	}

	private void performDirectBuild(GeneratorSettings settings,
			ref BuildSettings buildsettings, in Package pack, string config)
	{
		auto cwd = NativePath(getcwd());

		tracef("%s %s: building configuration %s", pack.name, pack.version_, config);

		// make all target/import paths relative
		string makeRelative(string path)
		{
			return shrinkPath(NativePath(path), cwd);
		}

		buildsettings.targetPath = makeRelative(buildsettings.targetPath);
		foreach (ref p; buildsettings.sourceFiles)
			p = makeRelative(p);
		foreach (ref p; buildsettings.importPaths)
			p = makeRelative(p);
		foreach (ref p; buildsettings.stringImportPaths)
			p = makeRelative(p);

		buildWithCompiler(settings, buildsettings);
	}

	private void buildWithCompiler(GeneratorSettings settings, BuildSettings buildsettings)
	{
		scope (failure)
		{
			tracef("FAIL %s %s %s" , buildsettings.targetPath,
					buildsettings.targetName, buildsettings.targetType);
		}

		buildsettings.libs = null;
		buildsettings.lflags = null;
		buildsettings.addOptions(BuildOption.syntaxOnly);
		buildsettings.sourceFiles = buildsettings.sourceFiles.filter!(f => !isLinkerFile(settings.platform, f)).array;
		trace("Build settings: ", buildsettings);

		settings.compiler.prepareBuildSettings(buildsettings, settings.platform, BuildSetting.commandLine);

		settings.compiler.invoke(buildsettings, settings.platform, settings.compileCallback);
	}
}

private string shrinkPath(NativePath path, NativePath base)
{
	auto orig = path.toNativeString();
	if (!path.absolute)
		return orig;
	auto ret = path.relativeTo(base).toNativeString();
	return ret.length < orig.length ? ret : orig;
}
