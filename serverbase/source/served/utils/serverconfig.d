module served.utils.serverconfig;

import served.lsp.protocol : DocumentUri;

/// UDA event called when configuration for any workspace or the unnamed
/// workspace got changed.
///
/// Expected method signature:
/// ```d
/// @onConfigChanged
/// void changedConfig(ConfigWorkspace target, string[] paths, T config)
/// ```
/// where `T` is the template argument to `mixin ConfigHandler!T`.
enum onConfigChanged;

/// UDA event called when all workspaces are processed in configuration
/// changes.
///
/// Expected method signature:
/// ```d
/// @onConfigFinished
/// void configFinished(size_t count)
/// ```
enum onConfigFinished;

///
struct ConfigWorkspace
{
	/// Workspace URI, resolved to a local workspace URI, or null if none found.
	/// May be null for invalid workspaces or if this is the unnamed workspace.
	/// Check `isUnnamedWorkspace` to see if this is the unnamed workspace.
	DocumentUri uri;
	/// Only true _iff_ this config applies to the unnamed workspace (folder-less workspace)
	bool isUnnamedWorkspace;
	/// 0-based index which workspace is being processed out of the total count. (for progress reporting)
	size_t index;
	/// Number of workspaces which are being processed right now in total. (for progress reporting)
	size_t numWorkspaces;

	static ConfigWorkspace exactlyOne(DocumentUri uri)
	{
		return ConfigWorkspace(uri, false, 0, 1);
	}

	static ConfigWorkspace unnamedWorkspace()
	{
		return ConfigWorkspace(null, true, 0, 1);
	}

	string toString() const @safe {
		import std.conv : text;

		return isUnnamedWorkspace
			? "(unnamed workspace)"
			: uri;
	}
}

mixin template ConfigHandler(TConfig)
{
	import served.lsp.protocol;
	import served.lsp.jsonops;
	import served.utils.events;

	private struct TConfigHolder
	{
		import std.array;

		TConfig config;
		alias config this;

		private static void compare(string prefix, T)(ref Appender!(string[]) changed, ref T a, ref T b)
		{
			foreach (i, ref lhs; a.tupleof)
			{
				alias SubT = typeof(a.tupleof[i]);
				// if the value is a simple struct, which is assumed to be user-defined, go through it
				static if (is(SubT == struct)
					&& __traits(getAliasThis, SubT).length == 0
					&& !isVariant!SubT)
				{
					compare!(prefix ~ __traits(identifier, a.tupleof[i]) ~ ".")(changed,
						a.tupleof[i], b.tupleof[i]);
				}
				else
				{
					if (a.tupleof[i] != b.tupleof[i])
						changed ~= (prefix ~ __traits(identifier, a.tupleof[i]));
				}
			}
		}

		string[] replace(TConfig newConfig)
		{
			string[] ret;
			static foreach (i; 0 .. TConfig.tupleof.length)
				ret ~= replaceSection!i(newConfig.tupleof[i]);
			return ret;
		}

		string[] replaceSection(size_t tupleOfIdx)(typeof(TConfig.tupleof[tupleOfIdx]) newValue)
		{
			auto ret = appender!(string[]);
			compare!(__traits(identifier, TConfig.tupleof[tupleOfIdx]) ~ ".")(
				ret, config.tupleof[tupleOfIdx], newValue);
			config.tupleof[tupleOfIdx] = newValue;
			return ret.data;
		}

		string[] replaceAllSectionsJson(string[] settingJsons)
		{
			assert(settingJsons.length >= TConfig.tupleof.length);
			auto changed = appender!(string[]);
			static foreach (i; 0 .. TConfig.tupleof.length)
			{{
				auto json = settingJsons[i];
				if (json == `null` || json.isEmptyJsonObject)
					changed ~= this.replaceSection!i(typeof(TConfig.tupleof[i]).init);
				else
					changed ~= this.replaceSection!i(json.deserializeJson!(typeof(TConfig.tupleof[i])));
			}}
			return changed.data;
		}
	}

	TConfigHolder[DocumentUri] perWorkspaceConfigurationStore;
	TConfigHolder* _globalConfigurationFallback;
	DocumentUri _globalConfigurationUri;

	TConfigHolder* globalConfiguration(string caller = __FUNCTION__) @safe nothrow
	{
		if (!_globalConfigurationUri.length)
		{
			if (!_globalConfigurationFallback)
				assert(false, caller ~ " called while globalConfiguration wasn't initialized");
			return _globalConfigurationFallback;
		}

		if (auto config = _globalConfigurationUri in perWorkspaceConfigurationStore)
			return config;

		return _globalConfigurationFallback;
	}

	__gshared bool syncedConfiguration = false;
	__gshared bool syncingConfiguration = false;

	private __gshared bool _hasConfigurationCapability = false;
	private __gshared TConfig* initializeConfig = null;

	private __gshared bool nonStandardConfiguration = false;

	@onInitialize
	void postInit_setupConfig(InitializeParams params)
	{
		auto workspaces = params.getWorkspaceFolders;
		foreach (workspace; workspaces)
			perWorkspaceConfigurationStore[workspace.uri] = TConfigHolder.init;

		if (workspaces.length)
			_globalConfigurationUri = workspaces[0].uri;
		else
			_globalConfigurationFallback = new TConfigHolder();

		_hasConfigurationCapability = capabilities
			.workspace.orDefault
			.configuration.orDefault;

		if (!params.initializationOptions.isNone) {
			// we might have the following options
			// - nonStandardConfiguration - `bool`
			// - startupConfiguration - a Configuration object
			//
			// this lets us initialize with a configuration right away, without
			// waiting for a client - or an editor extension.
			//
			// Editor extensions can use `nonStandardConfiguration` to
			// circumvent limitations in the LSP frameworks they have to work
			// with.
			//
			// Users of nonStandardConfiguration: Nova D-veleop extension
			auto optionsRaw = params.initializationOptions.deref;
			if (optionsRaw.kind == JsonValue.Kind.object)
			{
				auto options = optionsRaw.get!(StringMap!JsonValue);

				const nsc = "nonStandardConfiguration" in options;
				if (nsc) {
					nonStandardConfiguration = nsc.get!bool;
				}

				const settings = "startupConfiguration" in options;
				if (settings) {
					initializeConfig = new TConfig();
					*initializeConfig = jsonValueTo!TConfig(*settings);
				}
			}
			else
			{
				warning("initializationOptions is not an object, cannot use it for config initialization");
			}
		}
	}

	@protocolNotification("initialized")
	void setupConfig_Initialized(InitializedParams params)
	{
		import served.utils.async : setTimeout;

		if (initializeConfig)
		{
			processConfigChange(*initializeConfig);
			initializeConfig = null;
		}
		else
		{
			// add 250ms timeout after `initialized` notification to give clients
			// the chance to send `workspace/didChangeConfiguration` proactively
			// before requesting all configs ourselves.
			enum waitTimeMs = 250;
			setTimeout({
				setupConfig_loadAfterTimeout();
			}, waitTimeMs);
		}
	}

	private void setupConfig_loadAfterTimeout()
	{
		if (!syncedConfiguration && !syncingConfiguration)
		{
			syncedConfiguration = true;
			if (_hasConfigurationCapability)
			{
				if (!syncConfiguration(null, 0, perWorkspaceConfigurationStore.length + 1))
					error("Syncing user configuration failed!");

				warning(
					"Didn't receive any configuration notification, manually requesting all configurations now");

				int i;
				foreach (uri, cfg; perWorkspaceConfigurationStore)
					syncConfiguration(uri, ++i, perWorkspaceConfigurationStore.length + 1);

				emitExtensionEvent!onConfigFinished(perWorkspaceConfigurationStore.length);
			}
			else
			{
				warning("This Language Client doesn't support configuration requests and also didn't send any "
					~ "configuration to serve-d. Initializing using default configuration");

				emitExtensionEvent!onConfigChanged(ConfigWorkspace.unnamedWorkspace, null, globalConfiguration.config);
			}
		}
	}

	@protocolNotification("workspace/didChangeConfiguration")
	void didChangeConfiguration(RootJsonToken params)
	{
		import std.exception;
		if (nonStandardConfiguration) { // client prefers non-standard API
			return;
		}
		enforce(params.json.looksLikeJsonObject, "invalid non-object parameter to didChangeConfiguration");
		auto settings = params.json.parseKeySlices!"settings".settings;
		enforce(settings.length, `didChangeConfiguration must contain a "settings" key`);

		processConfigChange(settings.deserializeJson!TConfig);
	}

	@protocolNotification("served/didChangeConfiguration")
	void didChangeConfigurationNonStd(RootJsonToken params)
	{
		import std.exception;
		info("switching to nonstandard configuration mechanism");
		nonStandardConfiguration = true; // client prefers non-standard API
		enforce(params.json.looksLikeJsonObject, "invalid non-object parameter to served/didChangeConfiguration");
		auto settings = params.json.parseKeySlices!"settings".settings;
		enforce(settings.length, `served/didChangeConfiguration must contain a "settings key"`);

		processConfigChange(settings.deserializeJson!TConfig);
	}

	private void processConfigChange(TConfig configuration, bool allowConfigurationRequest = true)
	{
		syncingConfiguration = true;
		scope (exit)
		{
			syncingConfiguration = false;
			syncedConfiguration = true;
		}

		if (_hasConfigurationCapability
			&& allowConfigurationRequest
			&& perWorkspaceConfigurationStore.length >= 2)
		{
			ConfigurationItem[] items;
			items = getGlobalConfigurationItems(); // default workspace
			const stride = TConfig.tupleof.length;

			foreach (uri, cfg; perWorkspaceConfigurationStore)
				items ~= getConfigurationItems(uri);

			trace("Re-requesting configuration from client because there is more than 1 workspace");
			auto res = rpc.sendRequest("workspace/configuration", ConfigurationParams(items));

			const expected = perWorkspaceConfigurationStore.length + 1;
			string[] settings = validateConfigurationItemsResponse(res, expected);
			if (!settings.length)
			{
				trace("Config request failed, so falling back to global config...");
				return processConfigChange(configuration, false);
			}

			for (size_t i = 0; i < expected; i++)
			{
				const isDefault = i == 0;
				auto workspace = isDefault
					? globalConfiguration
					: items[i * stride].scopeUri.deref in perWorkspaceConfigurationStore;

				if (!workspace)
				{
					error("Could not find workspace URI response ",
						items[i * stride].scopeUri.deref,
						" in requested configurations?");
					continue;
				}

				string[] changed = workspace.replaceAllSectionsJson(settings[i * stride .. $]);
				emitExtensionEvent!onConfigChanged(
					ConfigWorkspace(
						isDefault ? null : items[i * stride].scopeUri.deref,
						isDefault,
						i,
						expected
					), changed, workspace.config);
			}
		}
		else if (perWorkspaceConfigurationStore.length)
		{
			auto kv = perWorkspaceConfigurationStore.byKeyValue.front;
			if (perWorkspaceConfigurationStore.length > 1)
				error("Client does not support configuration request, only applying config for workspace ", kv.key);
			auto changed = kv.value.replace(configuration);
			emitExtensionEvent!onConfigChanged(
				ConfigWorkspace.exactlyOne(kv.key), changed, kv.value.config);
		}
		else
		{
			info("initializing config for global fallback workspace");

			auto changed = globalConfiguration.replace(configuration);
			emitExtensionEvent!onConfigChanged(
				ConfigWorkspace.unnamedWorkspace, changed, globalConfiguration.config);
		}

		emitExtensionEvent!onConfigFinished(perWorkspaceConfigurationStore.length);
	}

	bool syncConfiguration(string workspaceUri, size_t index = 0, size_t numConfigs = 0, bool addNew = false)
	{
		if (_hasConfigurationCapability)
		{
			if (addNew)
				perWorkspaceConfigurationStore[workspaceUri] = TConfigHolder.init;

			auto proj = workspaceUri in perWorkspaceConfigurationStore;
			if (!proj && workspaceUri.length)
			{
				error("Did not find workspace ", workspaceUri, " when syncing config?");
				return false;
			}
			else if (!proj)
			{
				proj = globalConfiguration;
			}

			ConfigurationItem[] items;
			if (workspaceUri.length)
				items = getConfigurationItems(workspaceUri);
			else
				items = getGlobalConfigurationItems();

			trace("Sending workspace/configuration request for ", workspaceUri);
			auto res = rpc.sendRequest("workspace/configuration", ConfigurationParams(items));

			string[] settings = validateConfigurationItemsResponse(res);
			if (!settings.length)
				return false;

			string[] changed = proj.replaceAllSectionsJson(settings);
			emitExtensionEvent!onConfigChanged(
				ConfigWorkspace(workspaceUri, workspaceUri.length == 0, index, numConfigs),
				changed, proj.config);
			return true;
		}
		else
			return false;
	}

	private ConfigurationItem[] getGlobalConfigurationItems()
	{
		ConfigurationItem[] items = new ConfigurationItem[TConfig.tupleof.length];
		foreach (i, section; TConfig.init.tupleof)
			items[i] = ConfigurationItem(Optional!string.init, opt(TConfig.tupleof[i].stringof));
		return items;
	}

	private ConfigurationItem[] getConfigurationItems(DocumentUri uri)
	{
		ConfigurationItem[] items = new ConfigurationItem[TConfig.tupleof.length];
		foreach (i, section; TConfig.init.tupleof)
			items[i] = ConfigurationItem(opt(uri), opt(TConfig.tupleof[i].stringof));
		return items;
	}

	private string[] validateConfigurationItemsResponse(scope return ref ResponseMessageRaw res,
			size_t expected = size_t.max)
	{
		if (!res.resultJson.looksLikeJsonArray)
		{
			error("Got invalid configuration response from language client. (not an array)");
			trace("Response: ", res);
			return null;
		}

		string[] settings;
		int i;
		res.resultJson.visitJsonArray!(v => i++);
		settings.length = i;
		i = 0;
		res.resultJson.visitJsonArray!(v => settings[i++] = v);

		if (settings.length % TConfig.tupleof.length != 0)
		{
			error("Got invalid configuration response from language client. (invalid length)");
			trace("Response: ", res);
			return null;
		}
		if (expected != size_t.max)
		{
			auto total = settings.length / TConfig.tupleof.length;
			if (total > expected)
			{
				warning("Loading different amount of workspaces than requested: requested ",
						expected, " but loading ", total);
			}
			else if (total < expected)
			{
				error("Didn't get all configs we asked for: requested ", expected, " but loading ", total);
				return null;
			}
		}
		return settings;
	}
}
