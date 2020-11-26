module served.utils.events;

struct protocolMethod
{
	string method;
}

struct postProtocolMethod
{
	string method;
}

struct protocolNotification
{
	string method;
}

/// Event called when all components have been registered but no workspaces have
/// been setup yet.
/// Signature: `()`
enum onRegisteredComponents;

/// Event called when a new workspaced instance is created. Called before dub or
/// fsworkspace is loaded.
/// Signature: `(WorkspaceD.Instance, string dir, string uri)`
enum onAddingProject;

/// Event called when a new project root is finished setting up. Called when all
/// components are loaded. DCD is loaded but not yet started at this point.
/// Signature: `(WorkspaceD.Instance, string dir, string rootFolderUri)`
enum onAddedProject;

struct EventProcessorConfig
{
	string[] allowedDuplicateMethods = ["object", "served", "std", "io", "workspaced", "fs"];
}

/// Implements the event processor for a given extension module exposing a
/// `members` field defining all potential methods.
mixin template EventProcessor(alias ExtensionModule, EventProcessorConfig config = EventProcessorConfig.init)
{
	import core.lifetime : forward;

	import std.algorithm;
	import std.json;
	import std.meta;
	import std.traits;

	import painlessjson;

	// duplicate method name check to avoid name clashes and unreadable error messages
	private string[] findDuplicates(string[] fields)
	{
		string[] dups;
		Loop: foreach (i, field; fields)
		{
			static foreach (allowed; config.allowedDuplicateMethods)
				if (field == allowed)
					continue Loop;

			if (fields[0 .. i].canFind(field) || fields[i + 1 .. $].canFind(field))
				dups ~= field;
		}
		return dups;
	}

	enum duplicates = findDuplicates([ExtensionModule.members]);
	static if (duplicates.length > 0)
	{
		pragma(msg, "duplicates: ", duplicates);
		static assert(false, "Found duplicate method handlers of same name");
	}

	/// Calls all protocol methods in `ExtensionModule` matching a certain method
	/// and method type.
	/// Params:
	///  UDA = The UDA to filter the methods with. This must define a string member
	///     called `method` which is compared with the runtime `method` argument.
	///  callback = The callback which is called for every matching function with
	///     the given UDA and method name. Called with arguments `(string name,
	///     void delegate() callSymbol, UDA uda)` where the `callSymbol` function is
	///     a parameterless function which automatically converts the JSON params
	///     and additional available arguments based on the method overload and
	///     calls it.
	///  returnFirst = If `true` the callback will be called at most once with any
	///     unspecified matching method. If `false` the callback will be called with
	///     all matching methods.
	///  method = the runtime method name to compare the UDA names with
	///  params = the JSON arguments for this protocol event, automatically
	///     converted to method arguments on demand.
	///  availableExtraArgs = static extra arguments available to pass to the method
	///     calls. `out`, `ref` and `lazy` are perserved given the method overloads.
	///     overloads may consume anywhere between 0 to Args.length of these
	///     arguments.
	/// Returns: `true` if any method has been called, `false` otherwise.
	bool emitProtocol(alias UDA, alias callback, bool returnFirst, Args...)(string method,
			JSONValue params, Args availableExtraArgs)
	{
		return iterateExtensionMethodsByUDA!(UDA, (name, symbol, uda) {
			if (uda.method == method)
			{
				debug (PerfTraceLog) mixin(traceStatistics(uda.method ~ ":" ~ name));

				alias symbolArgs = Parameters!symbol;

				auto callSymbol()
				{
					static if (symbolArgs.length == 0)
					{
						return symbol();
					}
					else static if (symbolArgs.length == 1)
					{
						return symbol(fromJSON!(symbolArgs[0])(params));
					}
					else static if (availableExtraArgs.length > 0
						&& symbolArgs.length <= 1 + availableExtraArgs.length)
					{
						return symbol(fromJSON!(symbolArgs[0])(params), forward!(
							availableExtraArgs[0 .. symbolArgs.length + -1]));
					}
					else
					{
						static assert(0, "Function for " ~ name ~ " can't have more than one argument");
					}
				}

				callback(name, &callSymbol, uda);
				return true;
			}
			else
				return false;
		}, returnFirst);
	}

	bool emitExtensionEvent(alias UDA, Args...)(Args args)
	{
		return iterateExtensionMethodsByUDA!(UDA, (name, symbol, uda) {
			symbol(forward!args);
			return true;
		}, false);
	}

	/// Iterates through all public methods in `ExtensionModule` annotated with the
	/// given UDA. For each matching function the callback paramter is called with
	/// the arguments being `(string name, Delegate symbol, UDA uda)`. `callback` is
	/// expected to return a boolean if the UDA values were a match.
	///
	/// Params:
	///  UDA = The UDA type to filter methods with. Methods can just have an UDA
	///     with this type and any values. See $(REF getUDAs, std.traits)
	///  callback = Called for every matching method. Expected to have 3 arguments
	///     being `(string name, Delegate symbol, UDA uda)` and returning `bool`
	///     telling if the uda values were a match or not. The Delegate is most
	///     often a function pointer to the given symbol and may differ between all
	///     calls.
	///
	///     If the UDA is a symbol and not a type (such as some enum manifest
	///     constant), then the UDA argument has no meaning and should not be used.
	///  returnFirst = if `true`, once callback returns `true` immediately return
	///     `true` for the whole function, otherwise `false`. If this is set to
	///     `false` then callback will be run on all symbols and this function
	///     returns `true` if any callback call has returned `true`.
	/// Returns: `true` if any callback returned `true`, `false` otherwise or if
	///     none were called. If `returnFirst` is set this function returns after
	///     the first successfull callback call.
	bool iterateExtensionMethodsByUDA(alias UDA, alias callback, bool returnFirst)()
	{
		bool found = false;
		foreach (name; ExtensionModule.members)
		{
			static if (__traits(compiles, __traits(getMember, ExtensionModule, name)))
			{
				// AliasSeq to workaround AliasSeq members
				alias symbols = AliasSeq!(__traits(getMember, ExtensionModule, name));
				static if (symbols.length == 1 && hasUDA!(symbols[0], UDA))
				{
					alias symbol = symbols[0];
					static if (isSomeFunction!(symbol) && __traits(getProtection, symbol) == "public")
					{
						static if (__traits(compiles, { enum uda = getUDAs!(symbol, UDA)[0]; }))
							enum uda = getUDAs!(symbol, UDA)[0];
						else
							enum uda = null;

						static if (returnFirst)
						{
							if (callback(name, &symbol, uda))
								return true;
						}
						else
						{
							if (callback(name, &symbol, uda))
								found = true;
						}
					}
				}
			}
		}

		return found;
	}
}
