module served.commands.test_provider;

import served.types;
import served.commands.symbol_search;
import served.utils.async : spawnFiber;

import workspaced.api;
import workspaced.coms;

import std.algorithm;
import std.experimental.logger;
import std.file : FileException;
import std.path : baseName;
import std.range;

/// Set to true by app.d if `--provide test-runner` is given
/// Makes serve-d emit unittests on every save
__gshared bool doTrackTests = false;

UnittestProject[DocumentUri] projectTests;

@onProjectAvailable
void onPreviewProjectForUnittest(WorkspaceD.Instance instance, string dir, string rootFolderUri)
{
	if (!doTrackTests)
		return;

	string rootUri = instance.cwd.uriFromFile;
	auto project = &projectTests.require(rootUri, UnittestProject(rootUri, null, null, true));

	rpc.notifyMethod("coded/pushProjectTests", *project);
}

@onAddedProject
void onDidAddProjectForUnittest(WorkspaceD.Instance instance, string dir, string rootFolderUri)
{
	if (!doTrackTests)
		return;

	spawnFiber({
		if (!instance.has!DubComponent)
			return;

		rescanProject(instance);
	}, 80);
}

@protocolNotification("textDocument/didSave")
void onDidSaveCheckForUnittest(DidSaveTextDocumentParams params)
{
	if (!doTrackTests)
		return;

	if (!params.textDocument.uri.endsWith(".d"))
		return;

	auto instance = backend.getBestInstance!DubComponent(params.textDocument.uri);
	if (!instance)
		return;

	spawnFiber({
		auto projectUri = workspace(params.textDocument.uri).folder.uri;

		auto project = &projectTests.require(projectUri, UnittestProject(projectUri));
		rescanFile(*project, params.textDocument);

		rpc.notifyMethod("coded/pushProjectTests", *project);
	}, 80);
}

@protocolNotification("served/rescanTests")
void rescanTests(RescanTestsParams params)
{
	string cwd = params.uri.length ? uriToFile(params.uri) : null;
	foreach (instance; backend.instances)
	{
		if (!cwd.length || instance.cwd == cwd)
		{
			if (auto lazyInstance = cast(LazyWorkspaceD.LazyInstance)instance)
			{
				if (cwd.length || lazyInstance.didCallAccess)
				{
					rescanProject(instance);
				}
			}
			else
			{
				rescanProject(instance);
			}
		}
	}
}

private void rescanFile(ref UnittestProject project, TextDocumentIdentifier documentIdentifier)
{
	auto document = documents[documentIdentifier.uri];
	auto symbols = provideDocumentSymbolsOld(DocumentSymbolParamsEx(documentIdentifier, true));

	UnittestInfo[] tests;

	foreach (test; symbols)
	{
		if (test.extendedType != SymbolKindEx.test)
			continue;

		string name = test.name;
		if (test.detail.length)
			name = test.detail;

		tests ~= UnittestInfo(test.name, name, test.containerName, test.location.range);
	}

	string modulename = backend.get!ModulemanComponent.moduleName(document.rawText);
	if (!modulename.length)
		modulename = "(file) " ~ documentIdentifier.uri.uriToFile.baseName;
	auto entry = UnittestModule(modulename, documentIdentifier.uri, tests);

	auto trisect = project.modules
		.assumeSorted!("a.moduleName < b.moduleName")
		.trisect(entry);

	if (trisect[1].length)
	{
		if (tests.length == 0) // remove
			project.modules = project.modules.remove(tests.length);
		else
			project.modules[trisect[0].length] = entry;
	}
	else if (tests.length)
	{
		project.modules = project.modules[0 .. trisect[0].length]
			~ entry
			~ project.modules[trisect[0].length .. $];
	}
}

private void rescanProject(WorkspaceD.Instance instance)
{
	import std.datetime.stopwatch : StopWatch;
	import std.path : buildNormalizedPath;

	DubComponent dub = instance.get!DubComponent;
	auto settings = dub.rootPackageBuildSettings();

	string rootUri = instance.cwd.uriFromFile;

	auto project = &projectTests.require(rootUri, UnittestProject(rootUri));

	StopWatch sw;
	sw.start();

	project.name = settings.packageName;
	project.needsLoad = false;
	project.modules = null;
	foreach (path; settings.sourceFiles)
	{
		auto fullPath = buildNormalizedPath(settings.packagePath, path);
		if (!fullPath.endsWith(".d", ".dpp", ".di"))
			continue;

		auto uri = fullPath.uriFromFile;

		bool tempLoad = documents.tryGet(uri) == Document.init;
		if (tempLoad)
		{
			try
			{
				documents.loadFromFilesystem(uri);
			}
			catch (FileException e)
			{
				warningf("Failed to read file %s for tests: %s", fullPath, e);
				continue;
			}
		}

		scope (exit)
			if (tempLoad)
				documents.unloadDocument(uri);

		try
		{
			rescanFile(*project, TextDocumentIdentifier(uri));
		}
		catch (Exception e)
		{
			warningf("Failed to analyze file %s for tests: %s", fullPath, e);
		}
	}

	rpc.notifyMethod("coded/pushProjectTests", *project);

	sw.stop();
	infof("Found %s modules with tests in %s (%s) in %s",
		project.modules.length,
		project.name,
		project.workspaceUri,
		sw.peek);
}

