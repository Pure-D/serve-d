# serve-d

![build status](https://github.com/Pure-D/serve-d/workflows/Run%20Unittests/badge.svg)
![deploy nightly](https://github.com/Pure-D/serve-d/workflows/Deploy%20Nightly/badge.svg)

Join the chat:

[![Join on Discord](https://discordapp.com/api/guilds/242094594181955585/widget.png?style=shield)](https://discord.gg/Bstj9bx)

[Microsoft language server protocol](https://github.com/Microsoft/language-server-protocol) implementation for [D](https://dlang.org) using [workspace-d](https://github.com/Pure-D/workspace-d).

This program is basically a combination of workspace-d and most of [code-d](https://github.com/Pure-D/code-d).

The purpose of this project is to give every editor the same capabilities and editing features as code-d with even less code required on the editor side than with workspace-d due to a more widely available protocol.

This is pretty much another abstraction layer on top of workspace-d to simplify and speed up extension development as most of the editor extension can now be written in D.

## Special Thanks

**Thanks to the following big GitHub sponsors** financially supporting the code-d/serve-d tools:

* Jaen ([@jaens](https://github.com/jaens))

_[become a sponsor](https://github.com/sponsors/WebFreak001)_

## Features

See [code-d wiki](https://github.com/Pure-D/code-d/wiki)

This implements most language features of the language server protocol for D and also a lot of support for other D related files such as vibe.d diet files and DlangUI DML files.

## Usage

To use serve-d you will need an [Editor](https://microsoft.github.io/language-server-protocol/implementors/tools/) (client) with support for the Language Server Protocol. Depending on the editor the initialization code might look different and will need to be adapted for each editor. This is relatively small though and can be done easily for all editors.

**Officially Supported Editors**

* Visual Studio Code: using [code-d](https://marketplace.visualstudio.com/items?itemName=webfreak.code-d)
* Atom: using [ide-d](https://atom.io/packages/ide-d)

_add LSP configurations using serve-d for other editors and PR them here!_

**Other Editor Guides**

* [vim](editor-vim.md)

### Command Line options

serve-d offers the following command line options to allow the LSP client to configure serve-d on startup:

| Option | Default | Description |
| ------ | ------- | ----------- |
| `-r` / `--require` | [] | (allows multiple, optional) List of options which this serve-d version needs to implement. serve-d will intentionally crash on startup if one of the given options is not supported by this version. Specifying or not specifying them will not change anything on runtime. Implemented features: `d` (PoC / unneeded), `workspaces` (multi-workspace support) |
| `-p` / `--provide` | [] | (allows multiple, optional) List of options to affect behavior of serve-d. Use this to indicate support for special editor features/extensions not covered by the LSP spec. Supported values: (see provides list below) |
| `-v` / `--version` | n/a | Prints the version to stdout and exists |
| `--logfile` | n/a | Overrides the logging output to log to a file instead of stderr for debug logs |
| `--loglevel` | `verbose` for debug/nightly builds, otherwise `info` | Changes the minimum log level when messages are logged. See `serve-d --help` for possible values |
| `--lang` | `en` | Changes the language of GUI messages to a supported translation |
| `--wait` | `false` | Waits for one second before starting (useful to be able to attach when debugging) |

#### `--provide` values

The following provide values are supported by serve-d and will improve interop with the editor:

**`--provide http`**

When this provide flag is set, serve-d will send a request to the client when it wants to download a file (commonly DCD server files) using the `coded/interactiveDownload` request.

If this is not set, an internal download function is used which calls `coded/logInstall` on the client on every progress event.

**`--provide implement-snippets`**

If this is set, the `served/implementMethods` request will return TextEdits with snippet strings inside of them as defined by vscode.

**`--provide context-snippets`**

If this is set, auto completion requests will also return built-in and custom defined snippets.

<!-- TODO: --provide test-runner + commands to implement -->

### Custom requests/notifications

serve-d defines a variety of custom requests and notifications for better editor integration. All requests starting with `coded/` are sent from serve-d to the client and all requests starting with `served/` are sent from client to serve-d at any time.

serve-d internally handles an active instance which is the instance where last a relevant command has been run. (such as auto complete) It will be used for some commands.

#### Request `served/sortImports`

**Parameter**: `SortImportsParams`

**Returns**: `TextEdit[]`

Command to sort all user imports in a block at a given position in given code. Returns a list of changes to apply. (Replaces the whole block currently if anything changed, otherwise empty)

```ts
interface SortImportsParams
{
	/** Text document to look in */
	textDocument: TextDocumentIdentifier;

	/** Location of cursor as standard offset */
	location: number;
}
```

#### Request `served/implementMethods`

**Parameter**: `ImplementMethodsParams`

**Returns**: `TextEdit[]`

Implements the interfaces or abstract classes of a specified class/interface. The given position must be on/inside the identifier of any subclass after the colon (`:`) in a class definition.

```ts
interface ImplementMethodsParams
{
	/** Text document to look in */
	textDocument: TextDocumentIdentifier;

	/** Location of cursor as standard offset */
	location: number;
}
```

#### Request `served/restartServer`

**Parameter**: none

**Returns**: `true`

Restarts all DCD servers started by this serve-d instance. Returns `true` once done.

#### Notification `served/killServer`

**Parameter**: none

Kills all DCD servers started by this serve-d instance.

#### Request `served/addDependencySnippet`

**Parameter**: `AddDependencySnippetParams`

**Returns**: `boolean`

Registers a snippet across the whole serve-d application which may be limited to given grammatical scopes.

Requires `--provide context-snippets`

Returns false if SnippetsComponent hasn't been loaded yet, otherwise true.

#### Notification `served/updateDCD`

**Parameter**: none

Manually triggers a DCD update either by compiling from source or downloading prebuilt binaries depending on the host system and serve-d. Excessively calls the `coded/logInstall` notification.

#### Request `served/listConfigurations`

**Parameter**: none

**Returns**: `string[]`

Returns an empty array if there is no active instance or if it doesn't have dub.

Otherwise returns the names of available [configurations](https://dub.pm/package-format-json.html#configurations) in dub.

#### Request `served/switchConfig`

**Parameter**: `string`

**Returns**: `bool`

Sets the current dub configuration for building and other tools. Returns true on success.

#### Request `served/getConfig`

**Parameter**: none

**Returns**: `string`

Returns the current dub configuration or null if there is no dub in the active instance.

#### Request `served/listArchTypes`

**Parameter**: none

**Returns**: `string[]`

Returns an empty array if there is no active instance or if it doesn't have dub.

Otherwise returns the names of available architectures in dub. (e.g. x86 or x86_64)

#### Request `served/switchArchType`

**Parameter**: `string`

**Returns**: `bool`

Sets the current architecture for building and other tools. Returns true on success.

#### Request `served/getArchType`

**Parameter**: none

**Returns**: `string`

Returns the current dub architecture or null if there is no dub in the active instance.

#### Request `served/listBuildTypes`

**Parameter**: none

**Returns**: `string[]`

Returns an empty array if there is no active instance or if it doesn't have dub.

Otherwise returns the names of available [build types](https://dub.pm/package-format-json.html#build-types) in dub.

#### Request `served/switchBuildType`

**Parameter**: `string`

**Returns**: `bool`

Sets the current dub build type for building and other tools. Returns true on success.

#### Request `served/getBuildType`

**Parameter**: none

**Returns**: `string`

Returns the current dub build type or null if there is no dub in the active instance.

#### Request `served/getCompiler`

**Parameter**: none

**Returns**: `string`

Returns the name of the current compiler.

#### Request `served/switchCompiler`

**Parameter**: `string`

**Returns**: `bool`

Sets the current compiler to use in dub for building and other tools. Returns true on success.

#### Request `served/addImport`

**Parameter**: `AddImportParams`

**Returns**: `ImportModification`

Parses the source code and returns code edits how to insert a given import into the code.

```ts
interface AddImportParams
{
	/** Text document to look in */
	textDocument: TextDocumentIdentifier;
	/** The name of the import to add */
	name: string;
	/** Location of cursor as standard offset */
	location: number;
	/** if `false`, the import will get added to the innermost block */
	insertOutermost?: boolean = true;
}

interface ImportModification
{
	/** Set if there was already an import which was renamed. (for example import io = std.stdio; would be "io") */
	rename: string;

	/** Array of replacements to add the import to the code */
	replacements: CodeReplacement[];
}

interface CodeReplacement
{
	/**
	 * Range what to replace. If both indices are the same its inserting.
	 *
	 * This value is specified as bytes offset from the UTF-8 source.
	 */
	size_t[2] range;

	/** Content to replace it with. Empty means remove. */
	string content;
}
```

#### Request `served/updateImports`

**Parameter**: `UpdateImportsParams`

**Returns**: `boolean`

Refreshes the dub dependencies from the local filesystem. Triggers a `coded/updateDubTree` notification on success and updates imports in DCD.

Returns true on success.

```ts
interface UpdateImportsParams
{
	/// set this to false to not emit progress updates for the UI
	reportProgress?: bool;
}
```

#### Request `served/listDependencies`

**Parameter**: `string` packageName

**Returns**: `DubDependency[]`

Lists the dependencies of a given dub package name. If no package name is given (empty string) then all dependencies of the current instance will be listed.

```ts
interface DubDependency
{
	/** The name of this package */
	name: string;
	/** The installed version of this dependency or null if it isn't downloaded/installed yet */
	version: string;
	/** Path to the directory in which the package resides or null if it's not stored in the local file system. */
	path: string;
	/** Description as given in dub package file */
	description: string;
	/** Homepage as given in dub package file */
	homepage: string;
	/** Authors as given in dub package file */
	authors: string[];
	/** Copyright as given in dub package file */
	copyright: string;
	/** License as given in dub package file */
	license: string;
	/** List of the names of subPackages as defined in the package */
	subPackages: string[];
	/** `true` if this dependency has other dependencies */
	hasDependencies: boolean;
	/** `true` if no package name was given and thus this dependency is a root dependency of the active project. */
	root: boolean;
}
```

#### Request `served/buildTasks`

**Parameter**: none

**Returns**: `Task[]`

Returns a list of build tasks for all dub instances in the project. Currently each with Build, Run, Rebuild and Test commands.

```ts
enum TaskGroup
{
	clean = "clean",
	build = "build",
	rebuild = "rebuild",
	test = "test"
}

interface Task
{
	/// the default JSON task
	definition: any;
	/// global | workspace | uri of workspace folder
	scope: string;
	/// command to execute
	exec: string[];
	/// name of the task
	name: string;
	/// true if this is a background task without shown console
	isBackground: boolean;
	/// Task source extension name
	source: string;
	/// clean | build | rebuild | test
	group: TaskGroup;
	/// problem matchers to use
	problemMatchers: string[];
}
```

#### Notification `served/convertDubFormat`

**Params**: `DubConvertRequest`

Starts a conversion of a dub.json/dub.sdl file to a given other format. Shows an error message in the UI if unsuccessful and triggers a `workspace/applyEdit` command when successful with the new content.

```ts
interface DubConvertRequest
{
	/** Text document to look in */
	textDocument: TextDocumentIdentifier;
	/** The format to convert the dub recipe to. (json, sdl) */
	newFormat: string;
}
```

#### Notification `served/installDependency`

**Params**: `InstallRequest`

Adds a dependency to the dub recipe file of the currently active instance (respecting indentation) and calls dub upgrade and updates imports afterwards.

Writes changes to the file system.

```ts
interface InstallRequest
{
	/** Name of the dub dependency */
	name: string;
	/** Version to install in the dub recipe file */
	version: string;
}
```

#### Notification `served/updateDependency`

**Params**: `UpdateRequest`

Changes a dependency in the dub recipe file of the currently active instance (respecting indentation) to the given version and calls dub upgrade and updates imports afterwards.

Does nothing if the dependency wasn't found in the dub recipe.

Writes changes to the file system.

```ts
interface UpdateRequest
{
	/** Name of the dub dependency */
	name: string;
	/** Version to install in the dub recipe file */
	version: string;
}
```

#### Notification `served/uninstallDependency`

**Params**: `UninstallRequest`

Removes a dependency from the dub recipe file of the currently active instance and calls dub upgrade and updates imports afterwards.

Writes changes to the file system.

```ts
interface UninstallRequest
{
	/** Name of the dub dependency */
	name: string;
}
```

#### Notification `served/doDscanner`

**Params**: `DocumentLinkParams`

Manually triggers DScanner linting on the given file. (respecting user configuration)

#### Request `served/searchFile`

**Params**: `string` query

**Returns**: `string[]`

Searches for a given filename (optionally also with subfolders) and returns all locations in the project and all dependencies including standard library where this file exists.

#### Request `served/findFilesByModule`

**Params**: `string` module

**Returns**: `string[]`

Lists all files with a given module name in the project and all dependencies and standard library.

#### Request `served/doDscanner`

**Params**: `DocumentLinkParams`

**Returns**: `DScannerIniSection[]`

Returns the current D-Scanner configuration for a given URI.

```ts
/// An ini section of the dscanner.ini which is written in form [name]
interface DScannerIniSection
{
	/// A textual human readable description of the section
	description: string;
	/// The name of the section as written in the ini
	name: string;
	/// Features which are children of this section
	features: DScannerIniFeature[]
}

/// A single feature in a dscanner.ini which can be turned on/off
interface DScannerIniFeature
{
	/// A textual human readable description of the value
	description: string;
	/// The name of the value
	name: string;
	/// Enables/disables the feature or enables it with being disabled in unittests
	enabled: "disabled" | "enabled" | "skip-unittest"
}
```

#### Request `served/getActiveDubConfig`

**Params**: none

Returns dub information for the currently active project (dub project where last
file was edited / opened / etc)

**Returns**: at least

```js
{
    "packagePath": string,
    "packageName": string,
    "targetPath": string,
    "targetName": string,
    "workingDirectory": string,
    "mainSourceFile": string,

    "dflags": string[],
    "lflags": string[],
    "libs": string[],
    "linkerFiles": string[],
    "sourceFiles": string[],
    "copyFiles": string[],
    "versions": string[],
    "debugVersions": string[],
    "importPaths": string[],
    "stringImportPaths": string[],
    "importFiles": string[],
    "stringImportFiles": string[],
    "preGenerateCommands": string[],
    "postGenerateCommands": string[],
    "preBuildCommands": string[],
    "postBuildCommands": string[],
    "preRunCommands": string[],
    "postRunCommands": string[]
}
```

#### Request `served/getProfileGCEntries`

**Params**: none

Returns all profilegc.log entries parsed and combined.

**Returns**: `ProfileGCEntry[]`

```js
interface ProfileGCEntry
{
	bytesAllocated: number;
	allocationCount: number;
	type: string; /// the function and/or type name
	uri: string; /// absolute, normalized uri
	displayFile: string; /// as parsed from file
	line: number; /// 1-based line number
}
```

------

#### Client notification `coded/updateSetting`

**Params**: `UpdateSettingParams`

Tells the client to update a user or workspace setting. This is done for updating the dcdClientPath and dcdServerPath on installation.

```ts
interface UpdateSettingParams
{
	/** The configuration section to update in (e.g. "d" or "dfmt") */
	section: string;
	/** The value to set the configuration value to */
	value: any;
	/** `true` if this is a configuration change across all instances and not just the active one */
	global: bool;
}
```

#### Client notification `coded/logInstall`

**Params**: `string` message

Instructs the client to log a message that has something to do with the installation routine of serve-d or dependencies.

#### Client notification `coded/initDubTree`

**Params**: none

Tells the client that dub has been loaded and the dependency tree can now be fetched.

#### Client notification `coded/updateDubTree`

**Params**: none

Tells the client that dub dependencies have been reloaded and should be redisplayed.

#### Client notification `coded/changedSelectedWorkspace`

**Params**: `WorkspaceState`

Tells the client when the active instance changed.

```ts
interface WorkspaceState
{
	/** URI to the workspace folder */
	uri: string;
	/** name of the workspace folder (or internal placeholder) */
	name: string;
	/** true if this instance has been initialized */
	initialized: boolean;
	/** true if this is the active instance */
	selected: boolean;
}
```

#### Client request `coded/interactiveDownload`

**Params**: `InteractiveDownload`

**Returns**: `boolean`

Instructs the client to download a file into a given output path using download UI.

This must be implemented if `--provide http` is given in the command line, otherwise this is not called.

```ts
interface InteractiveDownload
{
	/** The URL to download */
	url: string;

	/** The title to show in the UI popup for this download */
	title?: string;

	/** The file path to write the downloaded file to */
	output: string;
}
```

### User Configuration

The server has support for configuration for [these items](https://github.com/Pure-D/code-d/blob/50ca8ca2831403d50bac10681df87a77b1af1bc4/package.json#L168).

## Installation

**If you use an existing extension (code-d) you will not need to do these steps**

If you want to manually get the serve-d binaries or if you want to add installation support for your editor, check out the sections below. The extension code-d already does this automatically and there is no need to do it there.

Installing a pre-built binary:

[Grab latest stable ore pre-release with binaries from GitHub releases](https://github.com/Pure-D/serve-d/releases)

[Grab latest nightly binaries from GitHub releases](https://github.com/Pure-D/serve-d/releases/tag/nightly)

Manually building from source:
```
dub build
```

## Issues

If you have issues with any editors using serve-d, please [report an issue](https://github.com/Pure-D/serve-d/issues/new)
