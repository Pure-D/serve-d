module served.utils.events;

// disabling this version saves around 25 MiB CTFE RAM skipping duplication
// checks & linting (decreases error message readability though)
debug version = LintExtensionMembers;

/// Called for requests (not notifications) from the client to the server. This
/// UDA must be used at most once per method for regular methods. For methods
/// returning arrays (T[]) it's possible to register multiple functions with the
/// same method. In this case, if the client supports it, partial results will
/// be sent for each returning method, meaning the results are streamed. In case
/// the client does not support partial methods, all results will be
/// concatenated together and returned as one.
struct protocolMethod
{
	string method;
}

/// Called after the @protocolMethod for this method is handled. May have as
/// many handlers registered as needed. When the actual protocol method is a
/// partial method (multiple handlers, returning array) this will be ran on each
/// chunk returned by every handler. In that case the handler will be run
/// multiple times on different fibers.
struct postProtocolMethod
{
	string method;
}

/// UDA to annotate a request or notification parameter with to supress linting
/// warnings.
enum nonStandard;

/// UDA to annotate that a method performs sufficient synchronization to be able
/// to be passed around and spawned in different threads on each Fiber invocation.
enum threadable;

struct protocolNotification
{
	string method;
}

struct EventProcessorConfig
{
}

/// Hooks into initialization, possibly manipulating the InitializeResponse.
/// Called after the extension entry point `initialize()` method, but before the
/// initialize response was sent to the client.
///
/// If it's desired not to stall the initialization routine, use
/// `@postProtocolMethod("initialized")` instead of these UDAs, which runs in a
/// separate fiber after the response has been sent. Warning: other requests and
/// notifications may have been called within this switching time window, so
/// if these functions depend on what is being called in the initialize hook,
/// they will break.
///
/// Annotated method is expected to have this type signature:
/// ```d
/// @initializeHook
/// void myInitHook(InitializeParams params, ref InitializeResult result);
/// @onInitialize
/// void otherHook(InitializeParams params);
/// ```
enum initializeHook;
/// ditto
enum onInitialize;

/// Implements the event processor for a given extension module exposing a
/// `members` field defining all potential methods.
mixin template EventProcessor(alias ExtensionModule, EventProcessorConfig config = EventProcessorConfig.init)
{
	static if (__traits(compiles, { import core.lifetime : forward; }))
		import core.lifetime : forward;
	else
		import std.functional : forward;

	import served.lsp.protocol;

	import std.algorithm;
	import std.meta;
	import std.traits;

	static if (__traits(hasMember, ExtensionModule, "memberModules"))
		mixin EventProcessorCoreImpl!(ExtensionModule, config);
	else
		static assert(false, "Missing memberModules or members field in extension "
			~ ExtensionModule.stringof);

	/// Calls all protocol methods in `ExtensionModule` matching a certain method
	/// and method type.
	/// Params:
	///  UDA = The UDA to filter the methods with. This must define a string member
	///     called `method` which is compared with the runtime `method` argument.
	///  callback = The callback which is called for every matching function with
	///     the given UDA and method name. Called with arguments `(string name,
	///     symbol, Tuple arguments, UDA uda)` where `symbol` is the function to
	///     call with `arguments.expand` to call the matching method.
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
	///
	/// So the callback gets called like `callback(name, symbol, arguments, uda)`
	/// and the implementation can then call the symbol function using
	/// `symbol(arguments.expand)`.
	///
	/// This works around scoping issues and copies the arguments once more on
	/// invocation, causing ref/out parameters to get lost however. Allows to
	/// copy the arguments to other fibers for parallel processing.
	bool emitProtocol(alias UDA, alias callback, bool returnFirst, Args...)(string method,
			string params, Args availableExtraArgs)
	{
		import std.typecons : tuple;
		ensureImpure();

		return iterateExtensionMethodsByUDA!(UDA, (name, symbol, uda) {
			if (uda.method == method)
			{
				debug (PerfTraceLog) mixin(traceStatistics(uda.method ~ ":" ~ name));

				alias symbolArgs = Parameters!symbol;

				static if (symbolArgs.length == 0)
				{
					auto arguments = tuple();
				}
				else static if (symbolArgs.length == 1)
				{
					auto arguments = tuple(implParseParam!(symbolArgs[0])(params));
				}
				else static if (availableExtraArgs.length > 0
					&& symbolArgs.length <= 1 + availableExtraArgs.length)
				{
					auto arguments = tuple(implParseParam!(symbolArgs[0])(params),
						forward!availableExtraArgs);
				}
				else
				{
					static assert(0, "Function for " ~ name ~ " can't have more than one argument");
				}

				callback(name, symbol, arguments, uda);
				return true;
			}
			else
				return false;
		}, returnFirst);
	}

	bool emitExtensionEvent(alias UDA, Args...)(auto ref Args args)
	{
		ensureImpure();
		return iterateExtensionMethodsByUDA!(UDA, (name, symbol, uda) {
			symbol(forward!args);
			return true;
		}, false);
	}

	private static void ensureImpure() @nogc nothrow @safe
	{
	}

	version (D_Ddoc)
	{
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
		bool iterateExtensionMethodsByUDA(alias UDA, alias callback, bool returnFirst)();
	}

	private T implParseParam(T)(string params)
	{
		import served.lsp.protocol;

		try
		{
			if (params.length && params.ptr[0] == '[')
			{
				// positional parameter support
				// only supports passing a single argument
				string got;
				params.visitJsonArray!((item) {
					if (!got.length)
						got = item;
					else
						throw new Exception("Mismatched parameter count");
				});
				return got.deserializeJson!T;
			}
			else if (params.length && params.ptr[0] == '{')
			{
				// named parameter support
				// only supports passing structs (not parsing names of D method arguments)
				return params.deserializeJson!T;
			}
			else
			{
				// no parameters passed - parse empty JSON for the type or
				// use default value.
				static if (is(T == struct))
					return `{}`.deserializeJson!T;
				else
					return T.init;
			}
		}
		catch (Exception e)
		{
			ResponseError error;
			error.code = ErrorCode.invalidParams;
			error.message = "Failed converting input parameter `" ~ params ~ "` to needed type `" ~ T.stringof ~ "`: " ~ e.msg;
			error.data = JsonValue(e.toString);
			throw new MethodException(error);
		}
	}

}

/// don't use manually, this is only public to work with mixin templates.
mixin template EventProcessorCoreImpl(alias ExtensionModule, EventProcessorConfig config = EventProcessorConfig.init)
{
	version (LintExtensionMembers)
	{
		private static string formatCtfeWarning(string file, size_t line, size_t column, string type = "Hint")
		{
			import std.conv : to;

			return "\x1B[1m" ~ file ~ "(" ~ line.to!string ~ "," ~ column.to!string ~ "): \x1B[1;34m" ~ type ~ ": \x1B[m";
		}

		enum lintWarnings = ctLintEvents();
		static if (lintWarnings.length > 0)
		{
			pragma(msg, lintWarnings);
			static if (lintWarnings.canFind("Error:"))
				static assert(false, "Aborting due to EventProcessor errors");
		}

		private static string ctLintEvents()()
		{
			import std.string : chomp;

			static bool isInvalidMethodName(string methodName, AllowedMethods[] allowed)
			{
				if (!allowed.length)
					return false;

				foreach (a; allowed)
					foreach (m; a.methods)
						if (m == methodName)
							return false;
				return true;
			}

			static string formatMethodNameWarning(string methodName, AllowedMethods[] allowed,
				string codeName, string file, size_t line, size_t column)
			{
				string allowedStr = "";
				foreach (allow; allowed)
				{
					foreach (m; allow.methods)
					{
						if (allowedStr.length)
							allowedStr ~= ", ";
						allowedStr ~= "`" ~ m ~ "`";
					}
				}

				return formatCtfeWarning(file, line, column)
					~ "method " ~ codeName ~ " listens for event `" ~ methodName
					~ "`, but the type has set allowed methods to " ~ allowedStr
					~ ".\n\t\tNote: check back with the LSP specification, in case this is wrongly tagged or annotate parameter with @nonStandard.\n";
			}

			string lintResult;
			static foreach (mod; AliasSeq!(ExtensionModule, ExtensionModule.memberModules))
			{
				static foreach (name; __traits(allMembers, mod))
				{{
					// AliasSeq to workaround AliasSeq members
					alias symbols = AliasSeq!(__traits(getMember, mod, name));
					static if (symbols.length == 1)
					{
						alias symbol = symbols[0];

						static if (__traits(getProtection, symbol) == "public")
						{
							static if (getUDAs!(symbol, protocolMethod).length != 0)
								enum methodName = getUDAs!(symbol, protocolMethod)[0].method;
							else static if (getUDAs!(symbol, protocolNotification).length != 0)
								enum methodName = getUDAs!(symbol, protocolNotification)[0].method;
							else
								enum methodName = "";

							static if (methodName.length)
							{
								alias P = Parameters!symbol;
								static if (P.length == 1 && is(P[0] == struct)
									&& staticIndexOf!(nonStandard, __traits(getAttributes, P)) == -1)
								{
									enum allowedMethods = getUDAs!(P[0], AllowedMethods);
									static if (isInvalidMethodName(methodName, [allowedMethods]))
										lintResult ~= formatMethodNameWarning(methodName, [allowedMethods],
											name, __traits(getLocation, symbol));
								}
							}
						}
					}
				}}
			}

			return lintResult.chomp("\n");
		}
	}

	bool iterateExtensionMethodsByUDA(alias UDA, alias callback, bool returnFirst)()
	{
		bool found = false;
		static foreach (mod; AliasSeq!(ExtensionModule, ExtensionModule.memberModules))
		{
			static foreach (name; __traits(allMembers, mod))
			{{
				// AliasSeq to workaround AliasSeq members, which are multiple symbols
				alias symbols = AliasSeq!(__traits(getMember, mod, name));
				static if (symbols.length == 1
					&& __traits(getProtection, symbols[0]) == "public")
				{
					alias symbol = symbols[0];
					static if (getUDAs!(symbol, UDA).length != 0)
					{
						static assert (__traits(getOverloads, mod, name, true).length == 1,
							"UDA @" ~ UDA.stringof ~ " annotated method " ~ name
							~ " has more than one overload, which is not supported. Please rename.");
						static if (is(typeof(getUDAs!(symbol, UDA)[0])))
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
			}}
		}

		return found;
	}
}
