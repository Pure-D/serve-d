module workspaced.com.dcdext;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import core.thread;

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.file;
import std.functional;
import std.json;
import std.meta;
import std.range;
import std.string;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.com.dfmt;
import workspaced.com.importer;
import workspaced.dparseext;

import workspaced.visitors.classifier;
import workspaced.visitors.methodfinder;

public import workspaced.visitors.methodfinder : InterfaceDetails, FieldDetails,
	MethodDetails, ArgumentInfo;

@component("dcdext")
class DCDExtComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	static immutable CodeRegionProtection[] mixableProtection = [
		CodeRegionProtection.public_ | CodeRegionProtection.default_,
		CodeRegionProtection.package_, CodeRegionProtection.packageIdentifier,
		CodeRegionProtection.protected_, CodeRegionProtection.private_
	];

	/// Loads dcd extension methods. Call with `{"cmd": "load", "components": ["dcdext"]}`
	void load()
	{
		if (!refInstance)
			return;

		config.stringBehavior = StringBehavior.source;
	}

	/// Extracts calltips help information at a given position.
	/// The position must be within the arguments of the function and not
	/// outside the parentheses or inside some child call.
	///
	/// When generating the call parameters for a function definition, the position must be inside the normal parameters,
	/// otherwise the template arguments will be put as normal arguments.
	///
	/// Returns: the position of significant locations for parameter extraction.
	/// Params:
	///   code = code to analyze
	///   position = byte offset where to check for function arguments
	///   definition = true if this hints is a function definition (templates don't have an exclamation point '!')
	CalltipsSupport extractCallParameters(scope const(char)[] code, int position,
			bool definition = false)
	{
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		if (!tokens.length)
			return CalltipsSupport.init;
		// TODO: can probably use tokenIndexAtByteIndex here
		auto queuedToken = tokens.countUntil!(a => a.index >= position) - 1;
		if (queuedToken == -2)
			queuedToken = cast(ptrdiff_t) tokens.length - 1;
		else if (queuedToken == -1)
			return CalltipsSupport.init;

		// TODO: refactor code to be more readable
		// all this code does is:
		// - go back all tokens until a starting ( is found. (with nested {} scope checks for delegates and () for calls)
		//   - abort if not found
		//   - set "isTemplate" if directly before the ( is a `!` token and an identifier
		// - if inTemplate is true:
		//   - go forward to starting ( of normal arguments -- this code has checks if startParen is `!`, which currently can't be the case but might be useful
		// - else not in template arguments, so
		//   - if before ( comes a ) we are definitely in a template, so track back until starting (
		//   - otherwise check if it's even a template (single argument: `!`, then a token, then `(`)
		// - determine function name & all parents (strips out index operators)
		// - split template & function arguments
		// - return all information
		// it's reasonably readable with the variable names and that pseudo explanation there pretty much directly maps to the code,
		// so it shouldn't be too hard of a problem, it's just a lot return values per step and taking in multiple returns from previous steps.

		/// describes if the target position is inside template arguments rather than function arguments (only works for calls and not for definition)
		bool inTemplate;
		int activeParameter; // counted commas
		int depth, subDepth;
		/// contains opening parentheses location for arguments or exclamation point for templates.
		auto startParen = queuedToken;
		while (startParen >= 0)
		{
			const c = tokens[startParen];
			const p = startParen > 0 ? tokens[startParen - 1] : Token.init;

			if (c.type == tok!"{")
			{
				if (subDepth == 0)
				{
					// we went too far, probably not inside a function (or we are in a delegate, where we don't want calltips)
					return CalltipsSupport.init;
				}
				else
					subDepth--;
			}
			else if (c.type == tok!"}")
			{
				subDepth++;
			}
			else if (subDepth == 0 && c.type == tok!";")
			{
				// this doesn't look like function arguments anymore
				return CalltipsSupport.init;
			}
			else if (depth == 0 && !definition && c.type == tok!"!" && p.type == tok!"identifier")
			{
				inTemplate = true;
				break;
			}
			else if (c.type == tok!")")
			{
				depth++;
			}
			else if (c.type == tok!"(")
			{
				if (depth == 0 && subDepth == 0)
				{
					if (startParen > 1 && p.type == tok!"!" && tokens[startParen - 2].type
							== tok!"identifier")
					{
						startParen--;
						inTemplate = true;
					}
					break;
				}
				else
					depth--;
			}
			else if (depth == 0 && subDepth == 0 && c.type == tok!",")
			{
				activeParameter++;
			}
			startParen--;
		}

		if (startParen <= 0)
			return CalltipsSupport.init;

		/// Token index where the opening template parentheses or exclamation point is. At first this is only set if !definition but later on this is resolved.
		auto templateOpen = inTemplate ? startParen : 0;
		/// Token index where the normal argument parentheses start or 0 if it doesn't exist for this call/definition
		auto functionOpen = inTemplate ? 0 : startParen;

		bool hasTemplateParens = false;

		if (inTemplate)
		{
			// go forwards to function arguments
			if (templateOpen + 2 < tokens.length)
			{
				if (tokens[templateOpen + 1].type == tok!"(")
				{
					hasTemplateParens = true;
					templateOpen++;
					functionOpen = findClosingParenForward(tokens, templateOpen,
							"in template function open finder");
					functionOpen++;

					if (functionOpen >= tokens.length)
						functionOpen = 0;
				}
				else
				{
					// single template arg (can only be one token)
					// https://dlang.org/spec/grammar.html#TemplateSingleArgument
					if (tokens[templateOpen + 2] == tok!"(")
						functionOpen = templateOpen + 2;
				}
			}
			else
				return CalltipsSupport.init; // syntax error
		}
		else
		{
			// go backwards to template arguments
			if (functionOpen > 0 && tokens[functionOpen - 1].type == tok!")")
			{
				// multi template args
				depth = 0;
				subDepth = 0;
				templateOpen = functionOpen - 1;
				const minTokenIndex = definition ? 1 : 2;
				while (templateOpen >= minTokenIndex)
				{
					const c = tokens[templateOpen];

					if (c == tok!")")
						depth++;
					else
					{
						if (depth == 1 && templateOpen > minTokenIndex && c.type == tok!"(")
						{
							if (definition
									? tokens[templateOpen - 1].type == tok!"identifier" : (tokens[templateOpen - 1].type == tok!"!"
										&& tokens[templateOpen - 2].type == tok!"identifier"))
								break;
						}

						if (depth == 0)
						{
							templateOpen = 0;
							break;
						}

						if (c == tok!"(")
							depth--;
					}

					templateOpen--;
				}

				if (templateOpen < minTokenIndex)
					templateOpen = 0;
				else
					hasTemplateParens = true;
			}
			else
			{
				// single template arg (can only be one token) or no template at all here
				if (functionOpen >= 3 && tokens[functionOpen - 2] == tok!"!"
						&& tokens[functionOpen - 3] == tok!"identifier")
				{
					templateOpen = functionOpen - 2;
				}
			}
		}

		depth = 0;
		subDepth = 0;
		bool inFuncName = true;
		auto callStart = (templateOpen ? templateOpen : functionOpen) - 1;
		auto funcNameStart = callStart;
		while (callStart >= 0)
		{
			const c = tokens[callStart];
			const p = callStart > 0 ? tokens[callStart - 1] : Token.init;

			if (c.type == tok!"]")
				depth++;
			else if (c.type == tok!"[")
			{
				if (depth == 0)
				{
					// this is some sort of `foo[(4` situation
					return CalltipsSupport.init;
				}
				depth--;
			}
			else if (c.type == tok!")")
				subDepth++;
			else if (c.type == tok!"(")
			{
				if (subDepth == 0)
				{
					// this is some sort of `foo((4` situation
					return CalltipsSupport.init;
				}
				subDepth--;
			}
			else if (depth == 0)
			{

				if (c.type.isCalltipable)
				{
					if (c.type == tok!"identifier" && p.type == tok!"." && (callStart < 2
							|| !tokens[callStart - 2].type.among!(tok!";", tok!",",
							tok!"{", tok!"}", tok!"(")))
					{
						// member function, traverse further...
						if (inFuncName)
						{
							funcNameStart = callStart;
							inFuncName = false;
						}
						callStart--;
					}
					else
					{
						break;
					}
				}
				else
				{
					// this is some sort of `4(5` or `if(4` situtation
					return CalltipsSupport.init;
				}
			}
			// we ignore stuff inside brackets and parens such as `foo[4](5).bar[6](a`
			callStart--;
		}

		if (inFuncName)
			funcNameStart = callStart;

		ptrdiff_t templateClose;
		if (templateOpen)
		{
			if (hasTemplateParens)
			{
				if (functionOpen)
					templateClose = functionOpen - 1;
				else
					templateClose = findClosingParenForward(tokens, templateOpen,
							"in template close finder");
			}
			else
				templateClose = templateOpen + 2;
		}
		//dfmt on
		auto functionClose = functionOpen ? findClosingParenForward(tokens,
				functionOpen, "in function close finder") : 0;

		CalltipsSupport.Argument[] templateArgs;
		if (templateOpen)
			templateArgs = splitArgs(tokens[templateOpen + 1 .. templateClose]);

		CalltipsSupport.Argument[] functionArgs;
		if (functionOpen)
			functionArgs = splitArgs(tokens[functionOpen + 1 .. functionClose]);

		return CalltipsSupport([
				tokens.tokenIndex(templateOpen),
				templateClose ? tokens.tokenEndIndex(templateClose) : 0
				], hasTemplateParens, templateArgs, [
				tokens.tokenIndex(functionOpen),
				functionClose ? tokens.tokenEndIndex(functionClose) : 0
				], functionArgs, funcNameStart != callStart, tokens.tokenIndex(funcNameStart),
				tokens.tokenIndex(callStart), inTemplate, activeParameter);
	}

	/// Finds the token range of the declaration at the given position.
	/// You can optionally decide if you want to include the function body in
	/// this range or not.
	size_t[2] getDeclarationRange(scope const(char)[] code, size_t position,
		bool includeDefinition)
	{
		RollbackAllocator rba;
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto parsed = parseModule(tokens, "getCodeBlockRange_input.d", &rba);
		auto reader = new DeclarationFinder(position, includeDefinition);
		reader.visit(parsed);
		reader.finish(code);
		return reader.range;
	}

	/// Finds the immediate surrounding code block at a position or returns CodeBlockInfo.init for none/module block.
	/// See_Also: CodeBlockInfo
	CodeBlockInfo getCodeBlockRange(scope const(char)[] code, int position)
	{
		RollbackAllocator rba;
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto parsed = parseModule(tokens, "getCodeBlockRange_input.d", &rba);
		auto reader = new CodeBlockInfoFinder(position);
		reader.visit(parsed);
		return reader.block;
	}

	/// Inserts a generic method after the corresponding block inside the scope where position is.
	/// If it can't find a good spot it will insert the code properly indented ata fitting location.
	// make public once usable
	private CodeReplacement[] insertCodeInContainer(string insert, scope const(char)[] code,
			int position, bool insertInLastBlock = true, bool insertAtEnd = true)
	{
		auto container = getCodeBlockRange(code, position);

		scope const(char)[] codeBlock = code[container.innerRange[0] .. container.innerRange[1]];

		RollbackAllocator rba;
		scope tokensInsert = getTokensForParser(cast(ubyte[]) insert, config,
				&workspaced.stringCache);
		scope parsedInsert = parseModule(tokensInsert, "insertCode_insert.d", &rba);

		scope insertReader = new CodeDefinitionClassifier(insert);
		insertReader.visit(parsedInsert);
		scope insertRegions = insertReader.regions.sort!"a.type < b.type".uniq.array;

		scope tokens = getTokensForParser(cast(ubyte[]) codeBlock, config, &workspaced.stringCache);
		scope parsed = parseModule(tokens, "insertCode_code.d", &rba);

		scope reader = new CodeDefinitionClassifier(codeBlock);
		reader.visit(parsed);
		scope regions = reader.regions;

		CodeReplacement[] ret;

		foreach (CodeDefinitionClassifier.Region toInsert; insertRegions)
		{
			auto insertCode = insert[toInsert.region[0] .. toInsert.region[1]];
			scope existing = regions.enumerate.filter!(a => a.value.sameBlockAs(toInsert));
			if (existing.empty)
			{
				const checkProtection = CodeRegionProtection.init.reduce!"a | b"(
						mixableProtection.filter!(a => (a & toInsert.protection) != 0));

				bool inIncompatible = false;
				bool lastFit = false;
				int fittingProtection = -1;
				int firstStickyProtection = -1;
				int regionAfterFitting = -1;
				foreach (i, stickyProtection; regions)
				{
					if (stickyProtection.affectsFollowing
							&& stickyProtection.protection != CodeRegionProtection.init)
					{
						if (firstStickyProtection == -1)
							firstStickyProtection = cast(int) i;

						if ((stickyProtection.protection & checkProtection) != 0)
						{
							fittingProtection = cast(int) i;
							lastFit = true;
							if (!insertInLastBlock)
								break;
						}
						else
						{
							if (lastFit)
							{
								regionAfterFitting = cast(int) i;
								lastFit = false;
							}
							inIncompatible = true;
						}
					}
				}
				assert(firstStickyProtection != -1 || !inIncompatible);
				assert(regionAfterFitting != -1 || fittingProtection == -1 || !inIncompatible);

				if (inIncompatible)
				{
					int insertRegion = fittingProtection == -1 ? firstStickyProtection : regionAfterFitting;
					insertCode = text(indent(insertCode, regions[insertRegion].minIndentation), "\n\n");
					auto len = cast(uint) insertCode.length;

					toInsert.region[0] = regions[insertRegion].region[0];
					toInsert.region[1] = regions[insertRegion].region[0] + len;
					foreach (ref r; regions[insertRegion .. $])
					{
						r.region[0] += len;
						r.region[1] += len;
					}
				}
				else
				{
					auto lastRegion = regions.back;
					insertCode = indent(insertCode, lastRegion.minIndentation).idup;
					auto len = cast(uint) insertCode.length;
					toInsert.region[0] = lastRegion.region[1];
					toInsert.region[1] = lastRegion.region[1] + len;
				}
				regions ~= toInsert;
				ret ~= CodeReplacement([toInsert.region[0], toInsert.region[0]], insertCode);
			}
			else
			{
				auto target = insertInLastBlock ? existing.tail(1).front : existing.front;

				insertCode = text("\n\n", indent(insertCode, regions[target.index].minIndentation));
				const codeLength = cast(int) insertCode.length;

				if (insertAtEnd)
				{
					ret ~= CodeReplacement([
							target.value.region[1], target.value.region[1]
							], insertCode);
					toInsert.region[0] = target.value.region[1];
					toInsert.region[1] = target.value.region[1] + codeLength;
					regions[target.index].region[1] = toInsert.region[1];
					foreach (ref other; regions[target.index + 1 .. $])
					{
						other.region[0] += codeLength;
						other.region[1] += codeLength;
					}
				}
				else
				{
					ret ~= CodeReplacement([
							target.value.region[0], target.value.region[0]
							], insertCode);
					regions[target.index].region[1] += codeLength;
					foreach (ref other; regions[target.index + 1 .. $])
					{
						other.region[0] += codeLength;
						other.region[1] += codeLength;
					}
				}
			}
		}

		return ret;
	}

	/// Implements the interfaces or abstract classes of a specified class/interface.
	/// Helper function which returns all functions as one block for most primitive use.
	Future!string implement(scope const(char)[] code, int position,
			bool formatCode = true, string[] formatArgs = [])
	{
		auto ret = new typeof(return);
		gthreads.create({
			mixin(traceTask);
			try
			{
				auto impl = implementAllSync(code, position, formatCode, formatArgs);

				auto buf = appender!string;
				string lastBaseClass;
				foreach (ref func; impl)
				{
					if (func.baseClass != lastBaseClass)
					{
						buf.put("// implement " ~ func.baseClass ~ "\n\n");
						lastBaseClass = func.baseClass;
					}

					buf.put(func.code);
					buf.put("\n\n");
				}
				ret.finish(buf.data.length > 2 ? buf.data[0 .. $ - 2] : buf.data);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		});
		return ret;
	}

	/// Implements the interfaces or abstract classes of a specified class/interface.
	/// The async implementation is preferred when used in background tasks to prevent disruption
	/// of other services as a lot of code is parsed and processed multiple times for this function.
	/// Params:
	/// 	code = input file to parse and edit.
	/// 	position = position of the superclass or interface to implement after the colon in a class definition.
	/// 	formatCode = automatically calls dfmt on all function bodys when true.
	/// 	formatArgs = sets the formatter arguments to pass to dfmt if formatCode is true.
	/// 	snippetExtensions = if true, snippets according to the vscode documentation will be inserted in place of method content. See https://code.visualstudio.com/docs/editor/userdefinedsnippets#_creating-your-own-snippets
	/// Returns: a list of newly implemented methods
	Future!(ImplementedMethod[]) implementAll(scope const(char)[] code, int position,
			bool formatCode = true, string[] formatArgs = [], bool snippetExtensions = false)
	{
		mixin(
				gthreadsAsyncProxy!`implementAllSync(code, position, formatCode, formatArgs, snippetExtensions)`);
	}

	/// ditto
	ImplementedMethod[] implementAllSync(scope const(char)[] code, int position,
			bool formatCode = true, string[] formatArgs = [], bool snippetExtensions = false)
	{
		auto tree = describeInterfaceRecursiveSync(code, position);
		auto availableVariables = tree.availableVariables;

		string[] implementedMethods = tree.details
			.methods
			.filter!"!a.needsImplementation"
			.map!"a.identifier"
			.array;

		int snippetIndex = 0;
		// maintains snippet ids and their value in an AA so they can be replaced after formatting
		string[string] snippetReplacements;

		auto methods = appender!(ImplementedMethod[]);
		void processTree(ref InterfaceTree tree)
		{
			auto details = tree.details;
			if (details.methods.length)
			{
				foreach (fn; details.methods)
				{
					if (implementedMethods.canFind(fn.identifier))
						continue;
					if (!fn.needsImplementation)
					{
						implementedMethods ~= fn.identifier;
						continue;
					}

					//dfmt off
					ImplementedMethod method = {
						baseClass: details.name,
						name: fn.name
					};
					//dfmt on
					auto buf = appender!string;

					snippetIndex++;
					bool writtenSnippet;
					string snippetId;
					auto snippetBuf = appender!string;

					void startSnippet(bool withDefault = true)
					{
						if (writtenSnippet || !snippetExtensions)
							return;
						snippetId = format!`/+++__WORKSPACED_SNIPPET__%s__+++/`(snippetIndex);
						buf.put(snippetId);
						swap(buf, snippetBuf);
						buf.put("${");
						buf.put(snippetIndex.to!string);
						if (withDefault)
							buf.put(":");
						writtenSnippet = true;
					}

					void endSnippet()
					{
						if (!writtenSnippet || !snippetExtensions)
							return;
						buf.put("}");

						swap(buf, snippetBuf);
						snippetReplacements[snippetId] = snippetBuf.data;
					}

					if (details.needsOverride)
						buf.put("override ");
					buf.put(fn.signature[0 .. $ - 1]);
					buf.put(" {");
					if (fn.optionalImplementation)
					{
						buf.put("\n\t");
						startSnippet();
						buf.put("// TODO: optional implementation\n");
					}

					string propertySearch;
					if (fn.signature.canFind("@property") && fn.arguments.length <= 1)
						propertySearch = fn.name;
					else if ((fn.name.startsWith("get") && fn.arguments.length == 0)
							|| (fn.name.startsWith("set") && fn.arguments.length == 1))
						propertySearch = fn.name[3 .. $];

					string foundProperty;
					if (propertySearch)
					{
						// frontOrDefault
						const matching = availableVariables.find!(a => fieldNameMatches(a.name,
								propertySearch));
						if (!matching.empty)
							foundProperty = matching.front.name;
					}

					if (foundProperty.length)
					{
						method.autoProperty = true;
						buf.put("\n\t");
						startSnippet();
						if (fn.returnType != "void")
						{
							method.getter = true;
							buf.put("return ");
						}

						if (fn.name.startsWith("set") || fn.arguments.length == 1)
						{
							method.setter = true;
							buf.put(foundProperty ~ " = " ~ fn.arguments[0].name);
						}
						else
						{
							// neither getter nor setter, but we will just put the property here anyway
							buf.put(foundProperty);
						}
						buf.put(";");
						endSnippet();
						buf.put("\n");
					}
					else if (fn.hasBody)
					{
						method.callsSuper = true;
						buf.put("\n\t");
						startSnippet();
						if (fn.returnType != "void")
							buf.put("return ");
						buf.put("super." ~ fn.name);
						if (fn.arguments.length)
							buf.put("(" ~ format("%(%s, %)", fn.arguments)
									.translate(['\\': `\\`, '{': `\{`, '$': `\$`, '}': `\}`]) ~ ")");
						else if (fn.returnType == "void")
							buf.put("()"); // make functions that don't return add (), otherwise they might be attributes and don't need that
						buf.put(";");
						endSnippet();
						buf.put("\n");
					}
					else if (fn.returnType != "void")
					{
						method.debugImpl = true;
						buf.put("\n\t");
						if (snippetExtensions)
						{
							startSnippet(false);
							buf.put('|');
							// choice snippet

							if (fn.returnType.endsWith("[]"))
								buf.put("return null; // TODO: implement");
							else
								buf.put("return " ~ fn.returnType.translate([
											'\\': `\\`,
											'{': `\{`,
											'$': `\$`,
											'}': `\}`,
											'|': `\|`,
											',': `\,`
										]) ~ ".init; // TODO: implement");

							buf.put(',');

							buf.put(`assert(false\, "Method ` ~ fn.name ~ ` not implemented");`);

							buf.put('|');
							endSnippet();
						}
						else
						{
							if (fn.isNothrowOrNogc)
							{
								if (fn.returnType.endsWith("[]"))
									buf.put("return null; // TODO: implement");
								else
									buf.put("return " ~ fn.returnType.translate([
												'\\': `\\`,
												'{': `\{`,
												'$': `\$`,
												'}': `\}`
											]) ~ ".init; // TODO: implement");
							}
							else
								buf.put(`assert(false, "Method ` ~ fn.name ~ ` not implemented");`);
						}
						buf.put("\n");
					}
					else if (snippetExtensions)
					{
						buf.put("\n\t");
						startSnippet(false);
						endSnippet();
						buf.put("\n");
					}

					buf.put("}");

					method.code = buf.data;
					methods.put(method);
				}
			}

			foreach (parent; tree.inherits)
				processTree(parent);
		}

		processTree(tree);

		if (formatCode && instance.has!DfmtComponent)
		{
			foreach (ref method; methods.data)
				method.code = instance.get!DfmtComponent.formatSync(method.code, formatArgs).strip;
		}

		foreach (ref method; methods.data)
		{
			// TODO: replacing using aho-corasick would be far more efficient but there is nothing like that in phobos
			foreach (key, value; snippetReplacements)
			{
				method.code = method.code.replace(key, value);
			}
		}

		return methods.data;
	}

	/// Looks up a declaration of a type and then extracts information about it as class or interface.
	InterfaceDetails lookupInterface(scope const(char)[] code, int position)
	{
		auto data = get!DCDComponent.findDeclaration(code, position).getBlocking;
		string file = data.file;
		int newPosition = data.position;

		if (!file.length || !newPosition)
			return InterfaceDetails.init;

		auto newCode = code;
		if (file != "stdin")
			newCode = readText(file);

		return getInterfaceDetails(file, newCode, newPosition);
	}

	/// Extracts information about a given class or interface at the given position.
	InterfaceDetails getInterfaceDetails(string file, scope const(char)[] code, int position)
	{
		RollbackAllocator rba;
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto parsed = parseModule(tokens, file, &rba);
		auto reader = new InterfaceMethodFinder(code, position);
		reader.visit(parsed);
		return reader.details;
	}

	Future!InterfaceTree describeInterfaceRecursive(scope const(char)[] code, int position)
	{
		mixin(gthreadsAsyncProxy!`describeInterfaceRecursiveSync(code, position)`);
	}

	InterfaceTree describeInterfaceRecursiveSync(scope const(char)[] code, int position)
	{
		auto baseInterface = getInterfaceDetails("stdin", code, position);

		InterfaceTree tree = InterfaceTree(baseInterface);

		InterfaceTree* treeByName(InterfaceTree* tree, string name)
		{
			if (tree.details.name == name)
				return tree;
			foreach (ref parent; tree.inherits)
			{
				InterfaceTree* t = treeByName(&parent, name);
				if (t !is null)
					return t;
			}
			return null;
		}

		void traverseTree(ref InterfaceTree sub)
		{
			foreach (i, parent; sub.details.parentPositions)
			{
				string parentName = sub.details.normalizedParents[i];
				if (treeByName(&tree, parentName) is null)
				{
					auto details = lookupInterface(sub.details.code, parent);
					details.name = parentName;
					sub.inherits ~= InterfaceTree(details);
				}
			}
			foreach (ref inherit; sub.inherits)
				traverseTree(inherit);
		}

		traverseTree(tree);

		return tree;
	}

	Related[] highlightRelated(scope const(char)[] code, int position)
	{
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		if (!tokens.length)
			return null;
		auto token = tokens.tokenIndexAtByteIndex(position);
		if (token >= tokens.length || !tokens[token].isLikeIdentifier)
			return null;

		Related[] ret;

		switch (tokens[token].type)
		{
		case tok!"static":
			if (token + 1 < tokens.length)
			{
				if (tokens[token + 1].type == tok!"if")
				{
					token++;
					goto case tok!"if";
				}
				else if (tokens[token + 1].type == tok!"foreach" || tokens[token + 1].type == tok!"foreach_reverse")
				{
					token++;
					goto case tok!"for";
				}
			}
			goto default;
		case tok!"if":
		case tok!"else":
			// if lister
			auto finder = new IfFinder();
			finder.target = tokens[token].index;
			RollbackAllocator rba;
			auto parsed = parseModule(tokens, "stdin", &rba);
			finder.visit(parsed);
			foreach (ifToken; finder.foundIf)
				ret ~= Related(Related.Type.controlFlow, [ifToken.index, ifToken.index + ifToken.tokenText.length]);
			break;
		case tok!"for":
		case tok!"foreach":
		case tok!"foreach_reverse":
		case tok!"while":
		case tok!"do":
		case tok!"break":
		case tok!"continue":
			// loop and switch matcher
			// special case for switch
			auto finder = new BreakFinder();
			finder.target = tokens[token].index;
			finder.isBreak = tokens[token].type == tok!"break";
			finder.isLoop = !(tokens[token].type == tok!"break" || tokens[token].type == tok!"continue");
			if (token + 1 < tokens.length && tokens[token + 1].type == tok!"identifier")
				finder.label = tokens[token + 1].text;
			RollbackAllocator rba;
			auto parsed = parseModule(tokens, "stdin", &rba);
			finder.visit(parsed);

			if (finder.isLoop && finder.foundBlock.length)
			{
				auto retFinder = new ReverseReturnFinder();
				retFinder.target = finder.target;
				retFinder.visit(parsed);
				finder.foundBlock ~= retFinder.returns;
				finder.foundBlock.sort!"a.index < b.index";
			}

			foreach (blockToken; finder.foundBlock)
				ret ~= Related(Related.Type.controlFlow, [blockToken.index, blockToken.index + blockToken.tokenText.length]);
			break;
		case tok!"switch":
		case tok!"case":
		case tok!"default":
			// switch/case lister
			auto finder = new SwitchFinder();
			finder.target = tokens[token].index;
			RollbackAllocator rba;
			auto parsed = parseModule(tokens, "stdin", &rba);
			finder.visit(parsed);
			foreach (switchToken; finder.foundSwitch)
				ret ~= Related(Related.Type.controlFlow, [switchToken.index, switchToken.index + switchToken.tokenText.length]);
			break;
		case tok!"return":
			// return effect lister
			auto finder = new ReturnFinder();
			finder.target = tokens[token].index;
			RollbackAllocator rba;
			auto parsed = parseModule(tokens, "stdin", &rba);
			finder.visit(parsed);
			foreach (switchToken; finder.related)
				ret ~= Related(Related.Type.controlFlow, [switchToken.index, switchToken.index + switchToken.tokenText.length]);
			break;
		default:
			// exact token / string matcher
			auto currentText = tokens[token].tokenText;
			foreach (i, tok; tokens)
			{
				if (tok.type == tokens[token].type && tok.text == tokens[token].text)
					ret ~= Related(Related.Type.exactToken, [tok.index, tok.index + currentText.length]);
				else if (tok.type.isSomeString && tok.evaluateExpressionString == currentText)
					ret ~= Related(Related.Type.exactString, [tok.index, tok.index + tok.text.length]);
			}
			break;
		}

		return ret;
	}

	FoldingRange[] getFoldingRanges(scope const(char)[] code)
	{
		auto ret = appender!(FoldingRange[]);
		LexerConfig config = this.config;

		config.whitespaceBehavior = WhitespaceBehavior.skip;
		config.commentBehavior = CommentBehavior.noIntern;

		auto tokens = appender!(Token[])();
		auto lexer = DLexer(code, config, &workspaced.stringCache);
		loop: foreach (token; lexer) switch (token.type)
		{
		case tok!"specialTokenSequence":
		case tok!"whitespace":
			break;
		case tok!"comment":
			auto commentText = token.text;
			if (commentText.canFind("\n"))
			{
				ret ~= FoldingRange(
					token.index,
					token.index + token.text.length,
					FoldingRangeType.comment
				);
			}
			break;
		case tok!"__EOF__":
			break loop;
		default:
			tokens.put(token);
			break;
		}

		if (!tokens.data.length)
			return ret.data;

		RollbackAllocator rba;
		auto tokensSlice = tokens.data;
		scope parsed = parseModule(tokensSlice, "getFoldingRanges_input.d", &rba);

		scope visitor = new FoldingRangeGenerator(tokensSlice);
		visitor.visit(parsed);
		foreach (found; visitor.ranges.data)
			if (found.start != -1 && found.end != -1)
				ret ~= found;

		if (has!ImporterComponent)
			foreach (importBlock; get!ImporterComponent.findImportCodeSlices(code))
				ret ~= FoldingRange(importBlock.start, importBlock.end, FoldingRangeType.imports);

		return ret.data;
	}

	/// Formats DCD definitions (symbol declarations) in a readable format.
	/// For functions this formats each argument in a separate line.
	/// For other symbols the definition is returned as-is.
	string formatDefinitionBlock(string definition)
	{
		// DCD definition help contains calltips for functions, which always end
		// with )
		if (!definition.endsWith(")"))
			return definition;

		auto tokens = getTokensForParser(cast(const(ubyte)[]) definition ~ ';',
			config, &workspaced.stringCache);
		if (!tokens.length)
			return definition;

		RollbackAllocator rba;
		auto parser = new Parser();
		parser.fileName = "stdin";
		parser.tokens = tokens;
		parser.messageFunction = null;
		parser.messageDelegate = null;
		parser.allocator = &rba;
		const Declaration decl = parser.parseDeclaration(
			false, // strict
			true // must be declaration (for constructor)
		);
		if (!decl)
			return definition;

		const FunctionDeclaration funcdecl = decl.functionDeclaration;
		const Constructor ctor = decl.constructor;
		if (!funcdecl && !ctor)
			return definition;

		auto ret = appender!string();
		ret.reserve(definition.length);

		if (funcdecl)
			ret.put(definition[0 .. funcdecl.name.index + funcdecl.name.text.length]);
		else if (ctor)
			ret.put("this");

		const templateParameters = funcdecl ? funcdecl.templateParameters : ctor.templateParameters;
		if (templateParameters && templateParameters.templateParameterList)
		{
			const params = templateParameters.templateParameterList.items;
			ret.put("(\n");
			foreach (i, param; params)
			{
				assert(param.tokens.length, "no tokens for template parameter?!");
				const start = param.tokens[0].index;
				const end = param.tokens[$ - 1].index + tokenText(param.tokens[$ - 1]).length;
				const hasNext = i + 1 < params.length;
				ret.put("\t");
				ret.put(definition[start .. end]);
				if (hasNext)
					ret.put(",");
				ret.put("\n");
			}
			ret.put(")");
		}

		const parameters = funcdecl ? funcdecl.parameters : ctor.parameters;
		if (parameters && (parameters.parameters.length || parameters.hasVarargs))
		{
			const params = parameters.parameters;
			ret.put("(\n");
			foreach (i, param; params)
			{
				assert(param.tokens.length, "no tokens for parameter?!");
				const start = param.tokens[0].index;
				const end = param.tokens[$ - 1].index + tokenText(param.tokens[$ - 1]).length;
				const hasNext = parameters.hasVarargs || i + 1 < params.length;
				ret.put("\t");
				ret.put(definition[start .. end]);
				if (hasNext)
					ret.put(",");
				ret.put("\n");
			}
			if (parameters.hasVarargs)
				ret.put("\t...\n");
			ret.put(")");
		}
		else
		{
			ret.put("()");
		}

		return ret.data;
	}

private:
	LexerConfig config;
}

///
enum CodeRegionType : int
{
	/// null region (unset)
	init,
	/// Imports inside the block
	imports = 1 << 0,
	/// Aliases `alias foo this;`, `alias Type = Other;`
	aliases = 1 << 1,
	/// Nested classes/structs/unions/etc.
	types = 1 << 2,
	/// Raw variables `Type name;`
	fields = 1 << 3,
	/// Normal constructors `this(Args args)`
	ctor = 1 << 4,
	/// Copy constructors `this(this)`
	copyctor = 1 << 5,
	/// Destructors `~this()`
	dtor = 1 << 6,
	/// Properties (functions annotated with `@property`)
	properties = 1 << 7,
	/// Regular functions
	methods = 1 << 8,
}

///
enum CodeRegionProtection : int
{
	/// null protection (unset)
	init,
	/// default (unmarked) protection
	default_ = 1 << 0,
	/// public protection
	public_ = 1 << 1,
	/// package (automatic) protection
	package_ = 1 << 2,
	/// package (manual package name) protection
	packageIdentifier = 1 << 3,
	/// protected protection
	protected_ = 1 << 4,
	/// private protection
	private_ = 1 << 5,
}

///
enum CodeRegionStatic : int
{
	/// null static (unset)
	init,
	/// non-static code
	instanced = 1 << 0,
	/// static code
	static_ = 1 << 1,
}

/// Represents a class/interface/struct/union/template with body.
struct CodeBlockInfo
{
	///
	enum Type : int
	{
		// keep the underlines in these values for range checking properly

		///
		class_,
		///
		interface_,
		///
		struct_,
		///
		union_,
		///
		template_,
	}

	static immutable string[] typePrefixes = [
		"class ", "interface ", "struct ", "union ", "template "
	];

	///
	Type type;
	///
	string name;
	/// Outer range inside the code spanning curly braces and name but not type keyword.
	uint[2] outerRange;
	/// Inner range of body of the block touching, but not spanning curly braces.
	uint[2] innerRange;

	string prefix() @property
	{
		return typePrefixes[cast(int) type];
	}
}

///
struct CalltipsSupport
{
	///
	struct Argument
	{
		/// Ranges of type, name and value not including commas or parentheses, but being right next to them. For calls this is the only important and accurate value.
		int[2] contentRange;
		/// Range of just the type, or for templates also `alias`
		int[2] typeRange;
		/// Range of just the name
		int[2] nameRange;
		/// Range of just the default value
		int[2] valueRange;
		/// True if the type declaration is variadic (using ...), or without typeRange a completely variadic argument
		bool variadic;

		/// Creates Argument(range, range, range, 0)
		static Argument templateType(int[2] range)
		{
			return Argument(range, range, range);
		}

		/// Creates Argument(range, 0, range, range)
		static Argument templateValue(int[2] range)
		{
			return Argument(range, typeof(range).init, range, range);
		}

		/// Creates Argument(range, 0, 0, 0, true)
		static Argument anyVariadic(int[2] range)
		{
			return Argument(range, typeof(range).init, typeof(range).init, typeof(range).init, true);
		}
	}

	bool hasTemplate() @property
	{
		return hasTemplateParens || templateArgumentsRange != typeof(templateArgumentsRange).init;
	}

	/// Range starting before exclamation point until after closing bracket or before function opening bracket.
	int[2] templateArgumentsRange;
	///
	bool hasTemplateParens;
	///
	Argument[] templateArgs;
	/// Range starting before opening parentheses until after closing parentheses.
	int[2] functionParensRange;
	///
	Argument[] functionArgs;
	/// True if the function is UFCS or a member function of some object or namespace.
	/// False if this is a global function call.
	bool hasParent;
	/// Start of the function itself.
	int functionStart;
	/// Start of the whole call going up all call parents. (`foo.bar.function` having `foo.bar` as parents)
	int parentStart;
	/// True if cursor is in template parameters
	bool inTemplateParameters;
	/// Number of the active parameter (where the cursor is) or -1 if in none
	int activeParameter = -1;
}

/// Represents one method automatically implemented off a base interface.
struct ImplementedMethod
{
	/// Contains the interface or class name from where this method is implemented.
	string baseClass;
	/// The name of the function being implemented.
	string name;
	/// True if an automatic implementation calling the base class has been made.
	bool callsSuper;
	/// True if a default implementation that should definitely be changed (assert or for nogc/nothrow simple init return) has been implemented.
	bool debugImpl;
	/// True if the method has been detected as property and implemented as such.
	bool autoProperty;
	/// True if the method is either a getter or a setter but not both. Is none for non-autoProperty methods but also when a getter has been detected but the method returns void.
	bool getter, setter;
	/// Actual code to insert for this class without class indentation but optionally already formatted.
	string code;
}

/// Contains details about an interface or class and all extended or implemented interfaces/classes recursively.
struct InterfaceTree
{
	/// Details of the template in question.
	InterfaceDetails details;
	/// All inherited classes in lexical order.
	InterfaceTree[] inherits;

	const(FieldDetails)[] availableVariables(bool onlyPublic = false) const
	{
		if (!inherits.length && !onlyPublic)
			return details.fields;

		// start with private, add all the public ones later in traverseTree
		auto ret = appender!(typeof(return));
		if (onlyPublic)
			ret.put(details.fields.filter!(a => !a.isPrivate));
		else
			ret.put(details.fields);

		foreach (sub; inherits)
			ret.put(sub.availableVariables(true));

		return ret.data;
	}
}

/// Represents one selection for things related to the queried cursor position.
struct Related
{
	///
	enum Type
	{
		/// token is the same as the selected token (except for non-text tokens)
		exactToken,
		/// string content is exactly equal to identifier text
		exactString,
		/// token is related to control flow:
		/// - all if/else keywords when checking any of them
		/// - loop/switch keyword when checking a break/continue
		controlFlow
	}

	/// The type of the related selection.
	Type type;
	/// Byte range [from-inclusive, to-exclusive] of the related selection.
	size_t[2] range;
}

/// Represents the kind of folding range
enum FoldingRangeType
{
	/// Represents a generic region, such as code blocks
	region,
	/// Emitted on comments that are larger than one line
	comment,
	/// Emitted on blocks of imports
	imports,
}

/// Represents a folding range where code can be collapsed.
struct FoldingRange
{
	/// Start and end byte positions (before the first character and after the
	/// last character respectively)
	size_t start, end;
	/// Describes what kind of range this is.
	FoldingRangeType type;
}

private:

bool isCalltipable(IdType type)
{
	return type == tok!"identifier" || type == tok!"assert" || type == tok!"import"
		|| type == tok!"mixin" || type == tok!"super" || type == tok!"this" || type == tok!"__traits";
}

int[2] tokenRange(const Token token)
{
	return [cast(int) token.index, cast(int)(token.index + token.tokenText.length)];
}

int tokenEnd(const Token token)
{
	return cast(int)(token.index + token.tokenText.length);
}

int tokenEnd(const Token[] token)
{
	if (token.length)
		return tokenEnd(token[$ - 1]);
	else
		return -1;
}

int tokenIndex(const(Token)[] tokens, ptrdiff_t i)
{
	if (i > 0 && i == tokens.length)
		return cast(int)(tokens[$ - 1].index + tokens[$ - 1].tokenText.length);
	return i >= 0 ? cast(int) tokens[i].index : 0;
}

int tokenEndIndex(const(Token)[] tokens, ptrdiff_t i)
{
	if (i > 0 && i == tokens.length)
		return cast(int)(tokens[$ - 1].index + tokens[$ - 1].text.length);
	return i >= 0 ? cast(int)(tokens[i].index + tokens[i].tokenText.length) : 0;
}

/// Returns the index of the closing parentheses in tokens starting at the opening parentheses which is must be at tokens[open].
ptrdiff_t findClosingParenForward(const(Token)[] tokens, ptrdiff_t open, string what = null)
in(tokens[open].type == tok!"(",
		"Calling findClosingParenForward must be done on a ( token and not on a " ~ str(
			tokens[open].type) ~ " token! " ~ what)
{
	if (open >= tokens.length || open < 0)
		return open;

	open++;

	int depth = 1;
	int subDepth = 0;
	while (open < tokens.length)
	{
		const c = tokens[open];

		if (c == tok!"(")
			depth++;
		else if (c == tok!"{")
			subDepth++;
		else if (c == tok!"}")
		{
			if (subDepth == 0)
				break;
			subDepth--;
		}
		else
		{
			if (c == tok!";" && subDepth == 0)
				break;

			if (c == tok!")")
				depth--;

			if (depth == 0)
				break;
		}

		open++;
	}
	return open;
}

CalltipsSupport.Argument[] splitArgs(const(Token)[] tokens)
{
	auto ret = appender!(CalltipsSupport.Argument[]);
	size_t start = 0;
	size_t valueStart = 0;

	int depth, subDepth;
	const targetDepth = tokens.length > 0 && tokens[0].type == tok!"(" ? 1 : 0;
	bool gotValue;

	void putArg(size_t end)
	{
		if (start >= end || start >= tokens.length)
			return;

		CalltipsSupport.Argument arg;

		auto typename = tokens[start .. end];
		arg.contentRange = [cast(int) typename[0].index, typename[$ - 1].tokenEnd];
		if (typename.length == 1)
		{
			auto t = typename[0];
			if (t.type == tok!"identifier" || t.type.isBasicType)
				arg = CalltipsSupport.Argument.templateType(t.tokenRange);
			else if (t.type == tok!"...")
				arg = CalltipsSupport.Argument.anyVariadic(t.tokenRange);
			else
				arg = CalltipsSupport.Argument.templateValue(t.tokenRange);
		}
		else
		{
			if (gotValue && valueStart > start && valueStart <= end)
			{
				typename = tokens[start .. valueStart];
				auto val = tokens[valueStart .. end];
				if (val.length)
					arg.valueRange = [cast(int) val[0].index, val[$ - 1].tokenEnd];
			}

			else if (typename.length == 1)
			{
				auto t = typename[0];
				if (t.type == tok!"identifier" || t.type.isBasicType)
					arg.typeRange = arg.nameRange = t.tokenRange;
				else
					arg.typeRange = t.tokenRange;
			}
			else if (typename.length)
			{
				if (typename[$ - 1].type == tok!"identifier")
				{
					arg.nameRange = typename[$ - 1].tokenRange;
					typename = typename[0 .. $ - 1];
				}
				else if (typename[$ - 1].type == tok!"...")
				{
					arg.variadic = true;
					if (typename.length > 1 && typename[$ - 2].type == tok!"identifier")
					{
						arg.nameRange = typename[$ - 2].tokenRange;
						typename = typename[0 .. $ - 2];
					}
					else
						typename = typename[0 .. 0];
				}

				if (typename.length)
					arg.typeRange = [cast(int) typename[0].index, typename[$ - 1].tokenEnd];
			}
		}

		ret.put(arg);

		gotValue = false;
		start = end + 1;
	}

	foreach (i, token; tokens)
	{
		if (token.type == tok!"{")
			subDepth++;
		else if (token.type == tok!"}")
		{
			if (subDepth == 0)
				break;
			subDepth--;
		}
		else if (token.type == tok!"(" || token.type == tok!"[")
			depth++;
		else if (token.type == tok!")" || token.type == tok!"]")
		{
			if (depth <= targetDepth)
				break;
			depth--;
		}

		if (depth == targetDepth)
		{
			if (token.type == tok!",")
				putArg(i);
			else if (token.type == tok!":" || token.type == tok!"=")
			{
				if (!gotValue)
				{
					valueStart = i + 1;
					gotValue = true;
				}
			}
		}
	}
	putArg(tokens.length);

	return ret.data;
}

auto indent(scope const(char)[] code, string indentation)
{
	return code.lineSplitter!(KeepTerminator.yes)
		.map!(a => a.length ? indentation ~ a : a)
		.join;
}

bool fieldNameMatches(string field, in char[] expected)
{
	import std.uni : sicmp;

	if (field.startsWith("_"))
		field = field[1 .. $];
	else if (field.startsWith("m_"))
		field = field[2 .. $];
	else if (field.length >= 2 && field[0] == 'm' && field[1].isUpper)
		field = field[1 .. $];

	return field.sicmp(expected) == 0;
}

final class CodeBlockInfoFinder : ASTVisitor
{
	this(int targetPosition)
	{
		this.targetPosition = targetPosition;
	}

	override void visit(const ClassDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.class_, dec.structBody);
	}

	override void visit(const InterfaceDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.interface_, dec.structBody);
	}

	override void visit(const StructDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.struct_, dec.structBody);
	}

	override void visit(const UnionDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.union_, dec.structBody);
	}

	override void visit(const TemplateDeclaration dec)
	{
		if (cast(int) targetPosition >= cast(int) dec.name.index && targetPosition < dec.endLocation)
		{
			block = CodeBlockInfo.init;
			block.type = CodeBlockInfo.Type.template_;
			block.name = dec.name.text;
			block.outerRange = [
				cast(uint) dec.name.index, cast(uint) dec.endLocation + 1
			];
			block.innerRange = [
				cast(uint) dec.startLocation + 1, cast(uint) dec.endLocation
			];
			dec.accept(this);
		}
	}

	private void visitContainer(const Token name, CodeBlockInfo.Type type, const StructBody structBody)
	{
		if (!structBody)
			return;
		if (cast(int) targetPosition >= cast(int) name.index && targetPosition < structBody.endLocation)
		{
			block = CodeBlockInfo.init;
			block.type = type;
			block.name = name.text;
			block.outerRange = [
				cast(uint) name.index, cast(uint) structBody.endLocation + 1
			];
			block.innerRange = [
				cast(uint) structBody.startLocation + 1, cast(uint) structBody.endLocation
			];
			structBody.accept(this);
		}
	}

	alias visit = ASTVisitor.visit;

	CodeBlockInfo block;
	int targetPosition;
}

version (unittest) static immutable string SimpleClassTestCode = q{
module foo;

class FooBar
{
public:
	int i; // default instanced fields
	string s;
	long l;

	public this() // public instanced ctor
	{
		i = 4;
	}

protected:
	int x; // protected instanced field

private:
	static const int foo() @nogc nothrow pure @system // private static methods
	{
		if (s == "a")
		{
			i = 5;
		}
	}

	static void bar1() {}

	void bar2() {} // private instanced methods
	void bar3() {}

	struct Something { string bar; }

	FooBar.Something somefunc() { return Something.init; }
	Something somefunc2() { return Something.init; }
}}.replace("\r\n", "\n");

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	assert(dcdext.getCodeBlockRange(SimpleClassTestCode, 123) == CodeBlockInfo(CodeBlockInfo.Type.class_,
			"FooBar", [20, SimpleClassTestCode.length], [
				28, SimpleClassTestCode.length - 1
			]));
	assert(dcdext.getCodeBlockRange(SimpleClassTestCode, 19) == CodeBlockInfo.init);
	assert(dcdext.getCodeBlockRange(SimpleClassTestCode, 20) != CodeBlockInfo.init);

	auto replacements = dcdext.insertCodeInContainer("void foo()\n{\n\twriteln();\n}",
			SimpleClassTestCode, 123);

	// TODO: make insertCodeInContainer work properly?
}

unittest
{
	import std.conv;

	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	auto extract = dcdext.extractCallParameters("int x; foo.bar(4, fgerg\n\nfoo(); int y;", 23);
	assert(!extract.hasTemplate);
	assert(extract.parentStart == 7);
	assert(extract.functionStart == 11);
	assert(extract.functionParensRange[0] == 14);
	assert(extract.functionParensRange[1] <= 31);
	assert(extract.functionArgs.length == 2);
	assert(extract.functionArgs[0].contentRange == [15, 16]);
	assert(extract.functionArgs[1].contentRange[0] == 18);
	assert(extract.functionArgs[1].contentRange[1] <= 31);

	extract = dcdext.extractCallParameters("int x; foo.bar(4, fgerg)\n\nfoo(); int y;", 23);
	assert(!extract.hasTemplate);
	assert(extract.parentStart == 7);
	assert(extract.functionStart == 11);
	assert(extract.functionParensRange == [14, 24]);
	assert(extract.functionArgs.length == 2);
	assert(extract.functionArgs[0].contentRange == [15, 16]);
	assert(extract.functionArgs[1].contentRange == [18, 23]);

	extract = dcdext.extractCallParameters("void foo()", 9, true);
	assert(extract != CalltipsSupport.init);
	extract = dcdext.extractCallParameters("void foo()", 10, true);
	assert(extract == CalltipsSupport.init);

	// caused segfault once, doesn't return anything important
	extract = dcdext.extractCallParameters(`SomeType!(int,"int_")foo(T,Args...)(T a,T b,string[string] map,Other!"(" stuff1,SomeType!(double,")double")myType,Other!"(" stuff,Other!")")`,
			140, true);
	assert(extract == CalltipsSupport.init);

	extract = dcdext.extractCallParameters(
			`auto bar(int foo, Button, my.Callback cb, ..., int[] arr ...)`, 60, true);
	assert(extract != CalltipsSupport.init);
	assert(!extract.hasTemplate);
	assert(!extract.inTemplateParameters);
	assert(extract.activeParameter == 4);
	assert(extract.functionStart == 5);
	assert(extract.parentStart == 5);
	assert(extract.functionParensRange == [8, 61]);
	assert(extract.functionArgs.length == 5);
	assert(extract.functionArgs[0].contentRange == [9, 16]);
	assert(extract.functionArgs[0].typeRange == [9, 12]);
	assert(extract.functionArgs[0].nameRange == [13, 16]);
	assert(extract.functionArgs[1].contentRange == [18, 24]);
	assert(extract.functionArgs[1].typeRange == [18, 24]);
	assert(extract.functionArgs[1].nameRange == [18, 24]);
	assert(extract.functionArgs[2].contentRange == [26, 40]);
	assert(extract.functionArgs[2].typeRange == [26, 37]);
	assert(extract.functionArgs[2].nameRange == [38, 40]);
	assert(extract.functionArgs[3].contentRange == [42, 45]);
	assert(extract.functionArgs[3].variadic);
	assert(extract.functionArgs[4].contentRange == [47, 60]);
	assert(extract.functionArgs[4].typeRange == [47, 52]);
	assert(extract.functionArgs[4].nameRange == [53, 56]);
	assert(extract.functionArgs[4].variadic);

	extract = dcdext.extractCallParameters(q{SomeType!(int, "int_") foo(T, Args...)(T a, T b, string[string] map, Other!"(" stuff1, SomeType!(double, ")double") myType, Other!"(" stuff, Other!")")},
			150, true);
	assert(extract != CalltipsSupport.init);
	assert(extract.hasTemplate);
	assert(extract.templateArgumentsRange == [26, 38]);
	assert(extract.templateArgs.length == 2);
	assert(extract.templateArgs[0].contentRange == [27, 28]);
	assert(extract.templateArgs[0].nameRange == [27, 28]);
	assert(extract.templateArgs[1].contentRange == [30, 37]);
	assert(extract.templateArgs[1].nameRange == [30, 34]);
	assert(extract.functionStart == 23);
	assert(extract.parentStart == 23);
	assert(extract.functionParensRange == [38, 151]);
	assert(extract.functionArgs.length == 7);
	assert(extract.functionArgs[0].contentRange == [39, 42]);
	assert(extract.functionArgs[0].typeRange == [39, 40]);
	assert(extract.functionArgs[0].nameRange == [41, 42]);
	assert(extract.functionArgs[1].contentRange == [44, 47]);
	assert(extract.functionArgs[1].typeRange == [44, 45]);
	assert(extract.functionArgs[1].nameRange == [46, 47]);
	assert(extract.functionArgs[2].contentRange == [49, 67]);
	assert(extract.functionArgs[2].typeRange == [49, 63]);
	assert(extract.functionArgs[2].nameRange == [64, 67]);
	assert(extract.functionArgs[3].contentRange == [69, 85]);
	assert(extract.functionArgs[3].typeRange == [69, 78]);
	assert(extract.functionArgs[3].nameRange == [79, 85]);
	assert(extract.functionArgs[4].contentRange == [87, 122]);
	assert(extract.functionArgs[4].typeRange == [87, 115]);
	assert(extract.functionArgs[4].nameRange == [116, 122]);
	assert(extract.functionArgs[5].contentRange == [124, 139]);
	assert(extract.functionArgs[5].typeRange == [124, 133]);
	assert(extract.functionArgs[5].nameRange == [134, 139]);
	assert(extract.functionArgs[6].contentRange == [141, 150]);
	assert(extract.functionArgs[6].typeRange == [141, 150]);

	extract = dcdext.extractCallParameters(`some_garbage(code); before(this); funcCall(4`, 44);
	assert(extract != CalltipsSupport.init);
	assert(!extract.hasTemplate);
	assert(extract.activeParameter == 0);
	assert(extract.functionStart == 34);
	assert(extract.parentStart == 34);
	assert(extract.functionArgs.length == 1);
	assert(extract.functionArgs[0].contentRange == [43, 44]);

	extract = dcdext.extractCallParameters(`some_garbage(code); before(this); funcCall(4, f(4)`, 50);
	assert(extract != CalltipsSupport.init);
	assert(!extract.hasTemplate);
	assert(extract.activeParameter == 1);
	assert(extract.functionStart == 34);
	assert(extract.parentStart == 34);
	assert(extract.functionArgs.length == 2);
	assert(extract.functionArgs[0].contentRange == [43, 44]);
	assert(extract.functionArgs[1].contentRange == [46, 50]);

	extract = dcdext.extractCallParameters(q{some_garbage(code); before(this); funcCall(4, ["a"], JSONValue(["b": JSONValue("c")]), recursive(func, call!s()), "texts )\"(too"},
			129);
	assert(extract != CalltipsSupport.init);
	assert(!extract.hasTemplate);
	assert(extract.functionStart == 34);
	assert(extract.parentStart == 34);
	assert(extract.functionArgs.length == 5);
	assert(extract.functionArgs[0].contentRange == [43, 44]);
	assert(extract.functionArgs[1].contentRange == [46, 51]);
	assert(extract.functionArgs[2].contentRange == [53, 85]);
	assert(extract.functionArgs[3].contentRange == [87, 112]);
	assert(extract.functionArgs[4].contentRange == [114, 129]);

	extract = dcdext.extractCallParameters(`void log(T t = T.x, A...)(A a) { call(Foo(["bar":"hello"])); } bool x() const @property { return false; } /// This is not code, but rather documentation`,
			127);
	assert(extract == CalltipsSupport.init);
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	auto info = dcdext.describeInterfaceRecursiveSync(SimpleClassTestCode, 23);
	assert(info.details.name == "FooBar");
	assert(info.details.blockRange == [27, 554]);
	assert(info.details.referencedTypes.length == 2);
	assert(info.details.referencedTypes[0].name == "Something");
	assert(info.details.referencedTypes[0].location == 455);
	assert(info.details.referencedTypes[1].name == "string");
	assert(info.details.referencedTypes[1].location == 74);

	assert(info.details.fields.length == 4);
	assert(info.details.fields[0].name == "i");
	assert(info.details.fields[1].name == "s");
	assert(info.details.fields[2].name == "l");
	assert(info.details.fields[3].name == "x");

	assert(info.details.types.length == 1);
	assert(info.details.types[0].type == TypeDetails.Type.struct_);
	assert(info.details.types[0].name == ["FooBar", "Something"]);
	assert(info.details.types[0].nameLocation == 420);

	assert(info.details.methods.length == 6);
	assert(info.details.methods[0].name == "foo");
	assert(
			info.details.methods[0].signature
			== "private static const int foo() @nogc nothrow pure @system;");
	assert(info.details.methods[0].returnType == "int");
	assert(info.details.methods[0].isNothrowOrNogc);
	assert(info.details.methods[0].hasBody);
	assert(!info.details.methods[0].needsImplementation);
	assert(!info.details.methods[0].optionalImplementation);
	assert(info.details.methods[0].definitionRange == [222, 286]);
	assert(info.details.methods[0].blockRange == [286, 324]);

	assert(info.details.methods[1].name == "bar1");
	assert(info.details.methods[1].signature == "private static void bar1();");
	assert(info.details.methods[1].returnType == "void");
	assert(!info.details.methods[1].isNothrowOrNogc);
	assert(info.details.methods[1].hasBody);
	assert(!info.details.methods[1].needsImplementation);
	assert(!info.details.methods[1].optionalImplementation);
	assert(info.details.methods[1].definitionRange == [334, 346]);
	assert(info.details.methods[1].blockRange == [346, 348]);

	assert(info.details.methods[2].name == "bar2");
	assert(info.details.methods[2].signature == "private void bar2();");
	assert(info.details.methods[2].returnType == "void");
	assert(!info.details.methods[2].isNothrowOrNogc);
	assert(info.details.methods[2].hasBody);
	assert(!info.details.methods[2].needsImplementation);
	assert(!info.details.methods[2].optionalImplementation);
	assert(info.details.methods[2].definitionRange == [351, 363]);
	assert(info.details.methods[2].blockRange == [363, 365]);

	assert(info.details.methods[3].name == "bar3");
	assert(info.details.methods[3].signature == "private void bar3();");
	assert(info.details.methods[3].returnType == "void");
	assert(!info.details.methods[3].isNothrowOrNogc);
	assert(info.details.methods[3].hasBody);
	assert(!info.details.methods[3].needsImplementation);
	assert(!info.details.methods[3].optionalImplementation);
	assert(info.details.methods[3].definitionRange == [396, 408]);
	assert(info.details.methods[3].blockRange == [408, 410]);

	assert(info.details.methods[4].name == "somefunc");
	assert(info.details.methods[4].signature == "private FooBar.Something somefunc();");
	assert(info.details.methods[4].returnType == "FooBar.Something");
	assert(!info.details.methods[4].isNothrowOrNogc);
	assert(info.details.methods[4].hasBody);
	assert(!info.details.methods[4].needsImplementation);
	assert(!info.details.methods[4].optionalImplementation);
	assert(info.details.methods[4].definitionRange == [448, 476]);
	assert(info.details.methods[4].blockRange == [476, 502]);

	// test normalization of types
	assert(info.details.methods[5].name == "somefunc2");
	assert(info.details.methods[5].signature == "private FooBar.Something somefunc2();",
			info.details.methods[5].signature);
	assert(info.details.methods[5].returnType == "FooBar.Something");
	assert(!info.details.methods[5].isNothrowOrNogc);
	assert(info.details.methods[5].hasBody);
	assert(!info.details.methods[5].needsImplementation);
	assert(!info.details.methods[5].optionalImplementation);
	assert(info.details.methods[5].definitionRange == [504, 526]);
	assert(info.details.methods[5].blockRange == [526, 552]);
}

unittest
{
	string testCode = q{package interface Foo0
{
	string stringMethod();
	Tuple!(int, string, Array!bool)[][] advancedMethod(int a, int b, string c);
	void normalMethod();
	int attributeSuffixMethod() nothrow @property @nogc;
	private
	{
		void middleprivate1();
		void middleprivate2();
	}
	extern(C) @property @nogc ref immutable int attributePrefixMethod() const;
	final void alreadyImplementedMethod() {}
	deprecated("foo") void deprecatedMethod() {}
	static void staticMethod() {}
	protected void protectedMethod();
private:
	void barfoo();
}}.replace("\r\n", "\n");

	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	auto info = dcdext.describeInterfaceRecursiveSync(testCode, 20);
	assert(info.details.name == "Foo0");
	assert(info.details.blockRange == [23, 523]);
	assert(info.details.referencedTypes.length == 3);
	assert(info.details.referencedTypes[0].name == "Array");
	assert(info.details.referencedTypes[0].location == 70);
	assert(info.details.referencedTypes[1].name == "Tuple");
	assert(info.details.referencedTypes[1].location == 50);
	assert(info.details.referencedTypes[2].name == "string");
	assert(info.details.referencedTypes[2].location == 26);

	assert(info.details.fields.length == 0);

	assert(info.details.methods[0 .. 4].all!"!a.hasBody");
	assert(info.details.methods[0 .. 4].all!"a.needsImplementation");
	assert(info.details.methods.all!"!a.optionalImplementation");

	assert(info.details.methods.length == 12);
	assert(info.details.methods[0].name == "stringMethod");
	assert(info.details.methods[0].signature == "string stringMethod();");
	assert(info.details.methods[0].returnType == "string");
	assert(!info.details.methods[0].isNothrowOrNogc);

	assert(info.details.methods[1].name == "advancedMethod");
	assert(info.details.methods[1].signature
			== "Tuple!(int, string, Array!bool)[][] advancedMethod(int a, int b, string c);");
	assert(info.details.methods[1].returnType == "Tuple!(int, string, Array!bool)[][]");
	assert(!info.details.methods[1].isNothrowOrNogc);

	assert(info.details.methods[2].name == "normalMethod");
	assert(info.details.methods[2].signature == "void normalMethod();");
	assert(info.details.methods[2].returnType == "void");

	assert(info.details.methods[3].name == "attributeSuffixMethod");
	assert(info.details.methods[3].signature == "int attributeSuffixMethod() nothrow @property @nogc;");
	assert(info.details.methods[3].returnType == "int");
	assert(info.details.methods[3].isNothrowOrNogc);

	assert(info.details.methods[4].name == "middleprivate1");
	assert(info.details.methods[4].signature == "private void middleprivate1();");
	assert(info.details.methods[4].returnType == "void");

	assert(info.details.methods[5].name == "middleprivate2");

	assert(info.details.methods[6].name == "attributePrefixMethod");
	assert(info.details.methods[6].signature
			== "extern (C) @property @nogc ref immutable int attributePrefixMethod() const;");
	assert(info.details.methods[6].returnType == "int");
	assert(info.details.methods[6].isNothrowOrNogc);

	assert(info.details.methods[7].name == "alreadyImplementedMethod");
	assert(info.details.methods[7].signature == "void alreadyImplementedMethod();");
	assert(info.details.methods[7].returnType == "void");
	assert(!info.details.methods[7].needsImplementation);
	assert(info.details.methods[7].hasBody);

	assert(info.details.methods[8].name == "deprecatedMethod");
	assert(info.details.methods[8].signature == `deprecated("foo") void deprecatedMethod();`);
	assert(info.details.methods[8].returnType == "void");
	assert(info.details.methods[8].needsImplementation);
	assert(info.details.methods[8].hasBody);

	assert(info.details.methods[9].name == "staticMethod");
	assert(info.details.methods[9].signature == `static void staticMethod();`);
	assert(info.details.methods[9].returnType == "void");
	assert(!info.details.methods[9].needsImplementation);
	assert(info.details.methods[9].hasBody);

	assert(info.details.methods[10].name == "protectedMethod");
	assert(info.details.methods[10].signature == `protected void protectedMethod();`);
	assert(info.details.methods[10].returnType == "void");
	assert(info.details.methods[10].needsImplementation);
	assert(!info.details.methods[10].hasBody);

	assert(info.details.methods[11].name == "barfoo");
	assert(info.details.methods[11].signature == `private void barfoo();`);
	assert(info.details.methods[11].returnType == "void");
	assert(!info.details.methods[11].needsImplementation);
	assert(!info.details.methods[11].hasBody);
}

unittest
{
	string testCode = q{module hello;

interface MyInterface
{
	void foo();
}

class ImplA : MyInterface
{

}

class ImplB : MyInterface
{
	void foo() {}
}
}.replace("\r\n", "\n");

	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	auto info = dcdext.getInterfaceDetails("stdin", testCode, 72);

	assert(info.blockRange == [81, 85]);
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	assert(dcdext.formatDefinitionBlock("Foo!(int, string) x") == "Foo!(int, string) x");
	assert(dcdext.formatDefinitionBlock("void foo()") == "void foo()");
	assert(dcdext.formatDefinitionBlock("void foo(string x)") == "void foo(\n\tstring x\n)");
	assert(dcdext.formatDefinitionBlock("void foo(string x,)") == "void foo(\n\tstring x\n)");
	assert(dcdext.formatDefinitionBlock("void foo(string x, int y)") == "void foo(\n\tstring x,\n\tint y\n)");
	assert(dcdext.formatDefinitionBlock("void foo(string, int)") == "void foo(\n\tstring,\n\tint\n)");
	assert(dcdext.formatDefinitionBlock("this(string, int)") == "this(\n\tstring,\n\tint\n)");
	assert(dcdext.formatDefinitionBlock("auto foo(string, int)") == "auto foo(\n\tstring,\n\tint\n)");
	assert(dcdext.formatDefinitionBlock("ComplexTemplate!(int, 'a', string, Nested!(Foo)) foo(string, int)")
		== "ComplexTemplate!(int, 'a', string, Nested!(Foo)) foo(\n\tstring,\n\tint\n)");
	assert(dcdext.formatDefinitionBlock("auto foo(T, V)(string, int)") == "auto foo(\n\tT,\n\tV\n)(\n\tstring,\n\tint\n)");
	assert(dcdext.formatDefinitionBlock("auto foo(string, int f, ...)") == "auto foo(\n\tstring,\n\tint f,\n\t...\n)");
}

final class IfFinder : ASTVisitor
{
	Token[] currentIf, foundIf;

	size_t target;

	alias visit = ASTVisitor.visit;

	static foreach (If; AliasSeq!(IfStatement, ConditionalStatement))
	override void visit(const If ifStatement)
	{
		if (foundIf.length)
			return;

		auto lastIf = currentIf;
		scope (exit)
			currentIf = lastIf;

		currentIf = [ifStatement.tokens[0]];

		static auto thenStatement(const If v)
		{
			static if (is(If == IfStatement))
				return v.thenStatement;
			else
				return v.trueStatement;
		}

		static auto elseStatement(const If v)
		{
			static if (is(If == IfStatement))
				return v.elseStatement;
			else
				return v.falseStatement;
		}

		if (thenStatement(ifStatement))
			thenStatement(ifStatement).accept(this);

		const(BaseNode) elseStmt = elseStatement(ifStatement);
		while (elseStmt)
		{
			auto elseToken = elseStmt.tokens.ptr - 1;

			// possible from if declarations
			if (elseToken.type == tok!"{" || elseToken.type == tok!":")
				elseToken--;

			if (elseToken.type == tok!"else")
			{
				if (!currentIf.length || currentIf[$ - 1] != *elseToken)
					currentIf ~= *elseToken;
			}

			if (auto elseIf = cast(IfStatement) elseStmt)
			{
				currentIf ~= elseIf.tokens[0];
				elseIf.accept(this);
				cast()elseStmt = elseIf.elseStatement;
			}
			else if (auto elseStaticIf = cast(ConditionalStatement) elseStmt)
			{
				currentIf ~= elseStaticIf.tokens[0];
				currentIf ~= elseStaticIf.tokens[1];
				elseStaticIf.accept(this);
				cast()elseStmt = elseStaticIf.falseStatement;
			}
			else if (auto declOrStatement = cast(DeclarationOrStatement) elseStmt)
			{
				if (declOrStatement.statement && declOrStatement.statement.statementNoCaseNoDefault)
				{
					if (declOrStatement.statement.statementNoCaseNoDefault.conditionalStatement)
					{
						cast()elseStmt = declOrStatement.statement.statementNoCaseNoDefault.conditionalStatement;
					}
					else if (declOrStatement.statement.statementNoCaseNoDefault.ifStatement)
					{
						cast()elseStmt = declOrStatement.statement.statementNoCaseNoDefault.ifStatement;
					}
					else
					{
						elseStmt.accept(this);
						cast()elseStmt = null;
					}
				}
				else if (declOrStatement.declaration && declOrStatement.declaration.conditionalDeclaration)
				{
					auto cond = declOrStatement.declaration.conditionalDeclaration;
					if (cond.trueDeclarations.length)
					{
						auto ifSearch = cond.trueDeclarations[0].tokens.ptr;
						while (!ifSearch.type.among!(tok!"if", tok!";", tok!"}", tok!"module"))
							ifSearch--;

						if (ifSearch.type == tok!"if")
						{
							if ((ifSearch - 1).type == tok!"static")
								currentIf ~= *(ifSearch - 1);
							currentIf ~= *ifSearch;
						}
					}

					if (cond.hasElse && cond.falseDeclarations.length == 1)
					{
						elseStmt.accept(this);
						cast()elseStmt = cast()cond.falseDeclarations[0];
					}
					else
					{
						elseStmt.accept(this);
						cast()elseStmt = null;
					}
				}
				else
				{
					elseStmt.accept(this);
					cast()elseStmt = null;
				}
			}
			else
			{
				elseStmt.accept(this);
				cast()elseStmt = null;
			}
		}

		saveIfMatching();
	}

	void saveIfMatching()
	{
		if (foundIf.length)
			return;

		foreach (v; currentIf)
			if (v.index == target)
			{
				foundIf = currentIf;
				return;
			}
	}
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	assert(dcdext.highlightRelated(`void foo()
{
	if (true) {}
	else static if (true) {}
	else if (true) {}
	else {}

	if (true) {}
	else static if (true) {}
	else {}
}`, 35) == [
	Related(Related.Type.controlFlow, [14, 16]),
	Related(Related.Type.controlFlow, [28, 32]),
	Related(Related.Type.controlFlow, [33, 39]),
	Related(Related.Type.controlFlow, [40, 42]),
	Related(Related.Type.controlFlow, [54, 58]),
	Related(Related.Type.controlFlow, [59, 61]),
	Related(Related.Type.controlFlow, [73, 77]),
]);

	assert(dcdext.highlightRelated(`void foo()
{
	if (true) {}
	else static if (true) {}
	else if (true) {}
	else {}

	if (true) {}
	else static if (true) { int a; }
	else { int b;}
}`, 83) == [
	Related(Related.Type.controlFlow, [83, 85]),
	Related(Related.Type.controlFlow, [97, 101]),
	Related(Related.Type.controlFlow, [102, 108]),
	Related(Related.Type.controlFlow, [109, 111]),
	Related(Related.Type.controlFlow, [131, 135]),
]);
}

final class SwitchFinder : ASTVisitor
{
	Token[] currentSwitch, foundSwitch;
	const(Statement) currentStatement;

	size_t target;

	alias visit = ASTVisitor.visit;

	override void visit(const SwitchStatement stmt)
	{
		if (foundSwitch.length)
			return;

		auto lastSwitch = currentSwitch;
		scope (exit)
			currentSwitch = lastSwitch;

		currentSwitch = [stmt.tokens[0]];
		stmt.accept(this);

		saveIfMatching();
	}

	override void visit(const CaseRangeStatement stmt)
	{
		if (currentStatement)
		{
			auto curr = currentStatement.tokens[0];
			if (curr.type == tok!"case")
				currentSwitch ~= curr;
		}
		auto last = *(stmt.high.tokens.ptr - 1);
		if (last.type == tok!"case")
			currentSwitch ~= last;
		stmt.accept(this);
	}

	override void visit(const CaseStatement stmt)
	{
		if (currentStatement)
		{
			auto curr = currentStatement.tokens[0];
			if (curr.type == tok!"case")
				currentSwitch ~= curr;
		}
		stmt.accept(this);
	}

	override void visit(const DefaultStatement stmt)
	{
		currentSwitch ~= stmt.tokens[0];
		stmt.accept(this);
	}

	override void visit(const Statement stmt)
	{
		auto last = currentStatement;
		scope (exit)
			cast()currentStatement = cast()last;
		cast()currentStatement = cast()stmt;
		stmt.accept(this);
	}

	void saveIfMatching()
	{
		if (foundSwitch.length)
			return;

		foreach (v; currentSwitch)
			if (v.index == target)
			{
				foundSwitch = currentSwitch;
				return;
			}
	}
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	assert(dcdext.highlightRelated(`void foo()
{
	switch (foo)
	{
		case 1: .. case 3:
			break;
		case 5:
			switch (bar)
			{
			case 6:
				break;
			default:
				break;
			}
			break;
		default:
			break;
	}
}`.normLF, 35) == [
	Related(Related.Type.controlFlow, [14, 20]),
	Related(Related.Type.controlFlow, [32, 36]),
	Related(Related.Type.controlFlow, [43, 47]),
	Related(Related.Type.controlFlow, [63, 67]),
	Related(Related.Type.controlFlow, [154, 161]),
]);
}

final class BreakFinder : ASTVisitor
{
	Token[] currentBlock, foundBlock;
	const(Statement) currentStatement;
	bool inSwitch;

	size_t target;
	bool isBreak; // else continue if not loop
	bool isLoop; // checking loop token (instead of break/continue)
	string label;

	alias visit = ASTVisitor.visit;

	override void visit(const LabeledStatement stmt)
	{
		if (foundBlock.length)
			return;

		if (label.length && label == stmt.identifier.text)
		{
			foundBlock = [stmt.identifier];
			return;
		}

		stmt.accept(this);
	}

	override void visit(const SwitchStatement stmt)
	{
		if (foundBlock.length)
			return;

		bool wasSwitch = inSwitch;
		scope (exit)
			inSwitch = wasSwitch;
		inSwitch = true;

		if (isBreak)
		{
			auto lastSwitch = currentBlock;
			scope (exit)
				currentBlock = lastSwitch;

			currentBlock = [stmt.tokens[0]];
			stmt.accept(this);

			saveIfMatching();
		}
		else
		{
			stmt.accept(this);
		}
	}

	static foreach (LoopT; AliasSeq!(ForeachStatement, StaticForeachDeclaration,
		StaticForeachStatement, ForStatement, WhileStatement))
	override void visit(const LoopT stmt)
	{
		if (foundBlock.length)
			return;

		auto lastSwitch = currentBlock;
		scope (exit)
			currentBlock = lastSwitch;

		currentBlock = [stmt.tokens[0]];
		stmt.accept(this);

		saveIfMatching();
	}

	override void visit(const DoStatement stmt)
	{
		if (foundBlock.length)
			return;

		auto lastSwitch = currentBlock;
		scope (exit)
			currentBlock = lastSwitch;

		currentBlock = [stmt.tokens[0]];
		auto whileTok = *(stmt.expression.tokens.ptr - 2);
		stmt.accept(this);
		if (whileTok.type == tok!"while")
			currentBlock ~= whileTok;

		saveIfMatching();
	}

	static foreach (IgnoreT; AliasSeq!(FunctionBody, FunctionDeclaration, StructBody))
	override void visit(const IgnoreT stmt)
	{
		if (foundBlock.length)
			return;

		auto lastSwitch = currentBlock;
		scope (exit)
			currentBlock = lastSwitch;

		currentBlock = null;
		stmt.accept(this);
	}

	override void visit(const CaseRangeStatement stmt)
	{
		if (isBreak)
		{
			if (currentStatement)
			{
				auto curr = currentStatement.tokens[0];
				if (curr.type == tok!"case")
					currentBlock ~= curr;
			}
			auto last = *(stmt.high.tokens.ptr - 1);
			if (last.type == tok!"case")
				currentBlock ~= last;
		}
		stmt.accept(this);
	}

	override void visit(const CaseStatement stmt)
	{
		if (currentStatement && isBreak)
		{
			auto curr = currentStatement.tokens[0];
			if (curr.type == tok!"case")
				currentBlock ~= curr;
		}
		stmt.accept(this);
	}

	override void visit(const DefaultStatement stmt)
	{
		if (isBreak)
			currentBlock ~= stmt.tokens[0];
		stmt.accept(this);
	}

	override void visit(const Statement stmt)
	{
		auto last = currentStatement;
		scope (exit)
			cast()currentStatement = cast()last;
		cast()currentStatement = cast()stmt;
		stmt.accept(this);
	}

	override void visit(const BreakStatement stmt)
	{
		if (stmt.tokens[0].index == target || isLoop)
			if (isBreak)
				currentBlock ~= stmt.tokens[0];
		stmt.accept(this);
	}

	override void visit(const ContinueStatement stmt)
	{
		// break token:
		//   continue in switch: ignore
		//   continue outside switch: include
		// other token:
		//   continue in switch: include
		//   continue outside switch: include
		if (stmt.tokens[0].index == target || isLoop)
			if (!(isBreak && inSwitch))
				currentBlock ~= stmt.tokens[0];
		stmt.accept(this);
	}

	void saveIfMatching()
	{
		if (foundBlock.length || label.length)
			return;

		foreach (v; currentBlock)
			if (v.index == target)
			{
				foundBlock = currentBlock;
				return;
			}
	}
}

class ReverseReturnFinder : ASTVisitor
{
	Token[] returns;
	size_t target;
	bool record;

	alias visit = ASTVisitor.visit;

	static foreach (DeclT; AliasSeq!(Declaration, Statement))
	override void visit(const DeclT stmt)
	{
		if (returns.length && !record)
			return;

		bool matches = stmt.tokens.length && stmt.tokens[0].index == target;
		if (matches)
			record = true;
		stmt.accept(this);
		if (matches)
			record = false;
	}

	override void visit(const ReturnStatement ret)
	{
		if (record)
			returns ~= ret.tokens[0];
		ret.accept(this);
	}
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	assert(dcdext.highlightRelated(`void foo()
{
	while (true)
	{
		foreach (a; b)
		{
			switch (a)
			{
			case 1:
				break;
			case 2:
				continue;
			default:
				return;
			}
		}
	}
}`.normLF, 88) == [
	Related(Related.Type.controlFlow, [54, 60]),
	Related(Related.Type.controlFlow, [73, 77]),
	Related(Related.Type.controlFlow, [85, 90]),
	Related(Related.Type.controlFlow, [95, 99]),
	Related(Related.Type.controlFlow, [120, 127]),
]);

	assert(dcdext.highlightRelated(`void foo()
{
	while (true)
	{
		foreach (a; b)
		{
			switch (a)
			{
			case 1:
				break;
			case 2:
				continue;
			default:
				return;
			}
		}
	}
}`.normLF, 111) == [
	Related(Related.Type.controlFlow, [32, 39]),
	Related(Related.Type.controlFlow, [107, 115]),
]);

	assert(dcdext.highlightRelated(`void foo()
{
	while (true)
	{
		foreach (a; b)
		{
			switch (a)
			{
			case 1:
				break;
			case 2:
				continue;
			default:
				return;
			}
		}
	}
}`.normLF, 15) == [
	Related(Related.Type.controlFlow, [14, 19]),
	Related(Related.Type.controlFlow, [133, 139]),
]);
}

class ReturnFinder : ASTVisitor
{
	Token[] returns;
	Token[] currentScope;
	bool inTargetBlock;
	Token[] related;
	size_t target;

	alias visit = ASTVisitor.visit;

	static foreach (DeclT; AliasSeq!(FunctionBody))
	override void visit(const DeclT stmt)
	{
		if (inTargetBlock || related.length)
			return;

		auto lastScope = currentScope;
		scope (exit)
			currentScope = lastScope;
		currentScope = null;

		auto lastReturns = returns;
		scope (exit)
			returns = lastReturns;
		returns = null;

		stmt.accept(this);
		if (inTargetBlock)
		{
			related ~= returns;

			related.sort!"a.index < b.index";
		}
	}

	static foreach (ScopeT; AliasSeq!(SwitchStatement, ForeachStatement,
		StaticForeachDeclaration, StaticForeachStatement, ForStatement, WhileStatement))
	override void visit(const ScopeT stmt)
	{
		auto lastScope = currentScope;
		scope (exit)
			currentScope = lastScope;
		currentScope ~= stmt.tokens[0];

		stmt.accept(this);
	}

	override void visit(const DoStatement stmt)
	{
		auto lastScope = currentScope;
		scope (exit)
			currentScope = lastScope;
		currentScope ~= stmt.tokens[0];

		auto whileTok = *(stmt.expression.tokens.ptr - 2);
		if (whileTok.type == tok!"while")
			currentScope ~= whileTok;

		stmt.accept(this);
	}

	override void visit(const ReturnStatement ret)
	{
		returns ~= ret.tokens[0];
		if (target == ret.tokens[0].index)
		{
			inTargetBlock = true;
			related ~= currentScope;
		}
		ret.accept(this);
	}
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	assert(dcdext.highlightRelated(`void foo()
{
	foreach (a; b)
		return;

	void bar()
	{
		return;
	}

	bar();

	return;
}`.normLF, 33) == [
	Related(Related.Type.controlFlow, [14, 21]),
	Related(Related.Type.controlFlow, [31, 37]),
	Related(Related.Type.controlFlow, [79, 85]),
]);
}

final class DeclarationFinder : ASTVisitor
{
	this(size_t targetPosition, bool includeDefinition)
	{
		this.targetPosition = targetPosition;
		this.includeDefinition = includeDefinition;
	}

	static foreach (DeclLike; AliasSeq!(Declaration, Parameter, TemplateDeclaration))
		override void visit(const DeclLike dec)
		{
			if (dec.tokens.length
				&& dec.tokens[0].index <= targetPosition
				&& dec.tokens[$ - 1].tokenEnd >= targetPosition)
			{
				deepest = cast()dec;
				static if (is(DeclLike == Parameter))
					definition = cast()dec.default_;
				else static if (is(DeclLike == TemplateDeclaration))
					definition = dec.declarations.length ? cast()dec.declarations[0] : null;
				else
					definition = null;
				dec.accept(this);
			}
		}

	override void visit(const Parameters p)
	{
		auto b = inParameter;
		inParameter = true;
		p.accept(this);
		inParameter = b;
	}

	static foreach (DefinitionOutsideParameter; AliasSeq!(FunctionBody, StructBody))
		override void visit(const DefinitionOutsideParameter defPart)
		{
			if (deepest !is null
				&& definition is null
				&& !inParameter
				&& defPart.tokens[0].index >= deepest.tokens[0].index
				&& defPart.tokens[0].index <= deepest.tokens[$ - 1].tokenEnd)
			{
				definition = cast()defPart;
			}
			auto b = inParameter;
			inParameter = false;
			defPart.accept(this);
			inParameter = b;
		}

	override void visit(const Initializer init)
	{
		if (deepest !is null
			&& definition is null
			&& init.tokens[0].index >= deepest.tokens[0].index
			&& init.tokens[0].index <= deepest.tokens[$ - 1].tokenEnd)
		{
			definition = cast()init;
		}
		init.accept(this);
	}

	alias visit = ASTVisitor.visit;

	void finish(scope const(char)[] code)
	{
		if (deepest is null)
			return;

		range = [
			deepest.tokens[0].index,
			deepest.tokens[$ - 1].tokenEnd
		];

		if (!includeDefinition && definition !is null)
		{
			range[1] = definition.tokens[0].index;
		}

		if (range[1] > code.length)
			range[1] = code.length;
		if (range[0] > range[1])
			range[0] = range[1];

		auto slice = code[range[0] .. range[1]];
		while (slice.length)
		{
			slice = slice.stripRight;
			if (slice.endsWith(";", "=", ",", "{"))
				slice = slice[0 .. $ - 1];
			else
				break;
		}
		range[1] = range[0] + slice.length;
	}

	BaseNode deepest;
	BaseNode definition;
	bool inParameter;
	size_t[2] range;
	size_t targetPosition;
	bool includeDefinition;
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	static immutable code = `void foo()
{
	foreach (a; b)
		return;

	void bar()
	{
		return;
	}

	auto foo = bar();

	int x = 1;

	@attr
	struct Foo
	{
		int field;
	}

	return;
}`.normLF;

	assert(dcdext.getDeclarationRange(code, 5, false) == [0, 10]);
	assert(dcdext.getDeclarationRange(code, 5, true) == [0, code.length]);
	assert(dcdext.getDeclarationRange(code, 46, false) == [41, 51]);
	assert(dcdext.getDeclarationRange(code, 46, true) == [41, 67]);
	assert(dcdext.getDeclarationRange(code, 75, false) == [70, 78]);
	assert(dcdext.getDeclarationRange(code, 75, true) == [70, 86]);
	assert(dcdext.getDeclarationRange(code, 94, false) == [90, 95]);
	assert(dcdext.getDeclarationRange(code, 94, true) == [90, 99]);
	assert(dcdext.getDeclarationRange(code, 117, false) == [103, 120]);
	assert(dcdext.getDeclarationRange(code, 117, true) == [103, 139]);
	assert(dcdext.getDeclarationRange(code, 130, false) == [126, 135]);
	assert(dcdext.getDeclarationRange(code, 130, true) == [126, 135]);

	static immutable tplCode = `template foo()
{
	static if (x)
	{
		alias foo = bar;
	}
}`.normLF;
	assert(dcdext.getDeclarationRange(tplCode, 9, false) == [0, 14]);
	assert(dcdext.getDeclarationRange(tplCode, 9, true) == [0, tplCode.length]);
}

class FoldingRangeGenerator : ASTVisitor
{
	enum supressBlockMixin = `bool _supressTmp = suppressThisBlock; suppressThisBlock = true; scope (exit) suppressThisBlock = _supressTmp;`;
	enum supressArgListMixin = `bool _supressTmp2 = suppressThisArgumentList; suppressThisArgumentList = true; scope (exit) suppressThisArgumentList = _supressTmp2;`;

	Appender!(FoldingRange[]) ranges;
	bool suppressThisBlock;
	bool suppressThisArgumentList;
	size_t lastCase = -1;
	const(Token)[] allTokens;

	this(const(Token)[] allTokens)
	{
		this.allTokens = allTokens;
		ranges = appender!(FoldingRange[]);
	}

	alias visit = ASTVisitor.visit;

	override void visit(const IfStatement stmt)
	{
		mixin(supressBlockMixin);

		if (stmt.thenStatement && stmt.condition)
			ranges.put(FoldingRange(
				// go 1 token over length because that's our `)` token (which should exist because stmt.thenStatement is defined)
				stmt.condition.tokens.via(allTokens, stmt.condition.tokens.length).tokenEnd,
				stmt.thenStatement.tokens.tokenEnd,
				FoldingRangeType.region));

		if (stmt.thenStatement && stmt.elseStatement)
			ranges.put(FoldingRange(
				// go 1 token over length because that's our `else` token (which should exist because stmt.elseStatement is defined)
				stmt.thenStatement.tokens.via(allTokens, stmt.thenStatement.tokens.length).tokenEnd,
				stmt.elseStatement.tokens.tokenEnd,
				FoldingRangeType.region));

		stmt.accept(this);
	}

	override void visit(const ConditionalStatement stmt)
	{
		mixin(supressBlockMixin);

		if (stmt.trueStatement && stmt.compileCondition)
			ranges.put(FoldingRange(
				stmt.compileCondition.tokens[$ - 1].tokenEnd,
				stmt.trueStatement.tokens.tokenEnd,
				FoldingRangeType.region));

		if (stmt.trueStatement && stmt.falseStatement)
			ranges.put(FoldingRange(
				// go 1 token over length because that's our `else` token (which should exist because stmt.falseStatement is defined)
				stmt.trueStatement.tokens.via(allTokens, stmt.trueStatement.tokens.length).tokenEnd,
				stmt.falseStatement.tokens.tokenEnd,
				FoldingRangeType.region));

		stmt.accept(this);
	}

	override void visit(const ConditionalDeclaration stmt)
	{
		mixin(supressBlockMixin);

		if (stmt.trueDeclarations.length)
		{
			auto lastTrueConditionToken = &stmt.compileCondition.tokens[$ - 1];
			// we go one over to see if there is a `:`
			if (stmt.trueStyle == DeclarationListStyle.colon
				&& lastTrueConditionToken[1].type == tok!":")
				lastTrueConditionToken++;
			ranges.put(FoldingRange(
				(*lastTrueConditionToken).tokenEnd,
				stmt.trueDeclarations[$ - 1].tokens.tokenEnd,
				FoldingRangeType.region));
		}

		if (stmt.hasElse && stmt.falseDeclarations.length)
		{
			auto elseToken = &stmt.falseDeclarations[0].tokens[0];
			foreach (i; 0 .. 4)
			{
				if ((*elseToken).type == tok!"else")
					break;
				elseToken--;
			}
			if ((*elseToken).type == tok!"else")
			{
				if (stmt.falseStyle == DeclarationListStyle.colon
					&& elseToken[1].type == tok!":")
					elseToken++;
				ranges.put(FoldingRange(
					(*elseToken).tokenEnd,
					stmt.falseDeclarations[$ - 1].tokens.tokenEnd,
					FoldingRangeType.region));
			}
		}

		stmt.accept(this);
	}

	override void visit(const SwitchStatement stmt)
	{
		mixin(supressBlockMixin);

		if (stmt.expression && stmt.statement)
			ranges.put(FoldingRange(
				// go 1 token over length because that's our `)` token (which should exist because stmt.statement is defined)
				stmt.expression.tokens.via(allTokens, stmt.expression.tokens.length).tokenEnd,
				stmt.tokens.tokenEnd,
				FoldingRangeType.region
			));

		stmt.accept(this);
	}

	static foreach (T; AliasSeq!(CaseStatement, DefaultStatement, CaseRangeStatement))
		override void visit(const T stmt)
		{
			if (stmt.declarationsAndStatements && stmt.declarationsAndStatements.declarationsAndStatements.length)
			{
				if (lastCase != -1 && ranges.data[lastCase].end == stmt.tokens.tokenEnd)
				{
					// fallthrough from previous case, adjust range of it
					ranges.data[lastCase].end = stmt.tokens.via(allTokens, -1).tokenEnd;
				}
				lastCase = ranges.data.length;
				ranges.put(FoldingRange(
					stmt.colonLocation + 1,
					stmt.tokens.tokenEnd,
					FoldingRangeType.region
				));
			}

			scope (exit)
				lastCase = -1;

			stmt.accept(this);
		}

	override void visit(const FunctionDeclaration decl)
	{
		mixin(supressBlockMixin);

		if (decl.parameters)
			ranges.put(FoldingRange(
				decl.parameters.tokens.tokenEnd,
				decl.tokens.tokenEnd,
				FoldingRangeType.region
			));

		decl.accept(this);
	}

	override void visit(const Unittest decl)
	{
		mixin(supressBlockMixin);

		size_t unittestTok = -1;
		foreach (i, t; decl.tokens)
		{
			if (t.type == tok!"unittest")
			{
				unittestTok = i;
				break;
			}
		}

		if (unittestTok != -1)
			ranges.put(FoldingRange(
				decl.tokens[unittestTok].tokenEnd,
				decl.tokens.tokenEnd,
				FoldingRangeType.region
			));

		decl.accept(this);
	}

	static foreach (Ctor; AliasSeq!(Constructor, Postblit, Destructor))
	override void visit(const Ctor stmt)
	{
		mixin(supressBlockMixin);

		if (stmt.functionBody && stmt.functionBody.tokens.length)
			ranges.put(FoldingRange(
				stmt.functionBody.tokens.via(allTokens, -1).tokenEnd,
				stmt.functionBody.tokens[$ - 1].tokenEnd,
				FoldingRangeType.region
			));
		
		stmt.accept(this);
	}

	override void visit(const BlockStatement stmt)
	{
		auto localSuppress = suppressThisBlock;
		if (!localSuppress)
			ranges.put(FoldingRange(
				stmt.startLocation,
				stmt.endLocation,
				FoldingRangeType.region
			));
		suppressThisBlock = false;
		scope (exit)
			suppressThisBlock = localSuppress;
		stmt.accept(this);
	}

	static foreach (T; AliasSeq!(
		ClassDeclaration,
		UnionDeclaration,
		StructDeclaration,
		InterfaceDeclaration,
		TemplateDeclaration
	))
		override void visit(const T decl)
		{
			mixin(supressBlockMixin);

			size_t start = decl.name.tokenEnd;
			if (decl.templateParameters)
				start = decl.templateParameters.tokens.tokenEnd;

			ranges.put(FoldingRange(
				start,
				decl.tokens.tokenEnd,
				FoldingRangeType.region
			));

			decl.accept(this);
		}

	override void visit(const StructBody stmt)
	{
		auto localSuppress = suppressThisBlock;
		if (!localSuppress)
			ranges.put(FoldingRange(
				stmt.startLocation,
				stmt.endLocation,
				FoldingRangeType.region
			));
		suppressThisBlock = false;
		scope (exit)
			suppressThisBlock = localSuppress;
		stmt.accept(this);
	}

	override void visit(const EnumBody stmt)
	{
		ranges.put(FoldingRange(
			stmt.tokens.via(allTokens, -1).tokenEnd,
			stmt.tokens[$ - 1].tokenEnd,
			FoldingRangeType.region
		));
		stmt.accept(this);
	}

	override void visit(const StaticForeachDeclaration decl)
	{
		mixin(supressBlockMixin);

		if (decl.declarations.length)
		{
			auto start = decl.declarations[0].tokens.ptr;
			foreach (i; 0 .. 4)
			{
				start--;
				if ((*start).type == tok!")")
					break;
			}
			if ((*start).type == tok!")")
			ranges.put(FoldingRange(
					(*start).tokenEnd,
				decl.tokens.tokenEnd,
				FoldingRangeType.region
			));
		}

		decl.accept(this);
	}

	static foreach (T; AliasSeq!(ForeachStatement, ForStatement, WhileStatement, WithStatement))
		override void visit(const T stmt)
		{
			mixin(supressBlockMixin);

			if (stmt.declarationOrStatement)
				ranges.put(FoldingRange(
					stmt.declarationOrStatement.tokens.via(allTokens, -1).tokenEnd,
					stmt.tokens.tokenEnd,
					FoldingRangeType.region
				));

			stmt.accept(this);
		}

	override void visit(const DoStatement stmt)
	{
		mixin(supressBlockMixin);

		if (stmt.statementNoCaseNoDefault && stmt.expression)
			ranges.put(FoldingRange(
				stmt.statementNoCaseNoDefault.tokens.via(allTokens, -1).tokenEnd,
				stmt.expression.tokens.via(allTokens, -2).index,
				FoldingRangeType.region
			));

		stmt.accept(this);
	}

	static foreach (T; AliasSeq!(ArrayLiteral, AssocArrayLiteral, ArrayInitializer, StructInitializer))
		override void visit(const T literal)
		{
			mixin(supressArgListMixin);

			if (literal.tokens.length > 2)
				ranges.put(FoldingRange(
					literal.tokens[0].tokenEnd,
					literal.tokens[$ - 1].index,
					FoldingRangeType.region
				));

			literal.accept(this);
		}

	override void visit(const AsmStatement stmt)
	{
		mixin(supressBlockMixin);

		if (stmt.functionAttributes.length)
			ranges.put(FoldingRange(
				stmt.functionAttributes[$ - 1].tokens.tokenEnd,
				stmt.tokens.tokenEnd,
				FoldingRangeType.region
			));
		else if (stmt.tokens.length > 3)
			ranges.put(FoldingRange(
				stmt.tokens[0].tokenEnd,
				stmt.tokens.tokenEnd,
				FoldingRangeType.region
			));

		stmt.accept(this);
	}

	override void visit(const FunctionLiteralExpression expr)
	{
		mixin(supressBlockMixin);

		if (expr.specifiedFunctionBody && expr.specifiedFunctionBody.tokens.length)
			ranges.put(FoldingRange(
				expr.specifiedFunctionBody.tokens[0].tokenEnd,
				expr.specifiedFunctionBody.tokens[$ - 1].index,
				FoldingRangeType.region
			));

		expr.accept(this);
	}

	static foreach (T; AliasSeq!(TemplateArgumentList, ArgumentList))
		override void visit(const T stmt)
		{
			auto localSuppress = suppressThisArgumentList;
			suppressThisArgumentList = false;
			scope (exit)
				suppressThisArgumentList = localSuppress;

			stmt.accept(this);

			// add this after other ranges (so they are prioritized)
			if (!localSuppress && stmt.tokens.length && stmt.tokens[0].line != stmt.tokens[$ - 1].line)
				ranges.put(FoldingRange(
					stmt.tokens.via(allTokens, -1).tokenEnd,
					stmt.tokens[$ - 1].tokenEnd,
					FoldingRangeType.region
				));
		}
}

unittest
{
	scope backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	auto foldings = dcdext.getFoldingRanges(`/**
 * This does foo
 */
void foo()
{
	foreach (a; b)
		return;

	if (foo)
	{
		if (bar)
			doFoo();
		else
			doBar();
		ok();
	} else
		doBaz();

	void bar()
	{
		return;
	}

	switch (x)
	{
		case 1:
		case 2:
			writeln("1 or 2");
			break;
		case 3:
			writeln("drei");
			break;
		default:
			writeln("default");
			break;
	}

	return;
}`.normLF);

	assert(foldings == [
		FoldingRange(0, 24, FoldingRangeType.comment),
		FoldingRange(35, 342),
		FoldingRange(53, 63),
		FoldingRange(74, 130),
		FoldingRange(135, 146),
		FoldingRange(88, 100),
		FoldingRange(107, 119),
		FoldingRange(159, 175),
		FoldingRange(188, 330),
		FoldingRange(211, 243),
		FoldingRange(253, 283), // wrong case end
		FoldingRange(294, 327),
	], foldings.map!(to!string).join(",\n"));

	assert(dcdext.getFoldingRanges(`unittest {
}`.normLF) == [FoldingRange(8, 12)]);

	assert(dcdext.getFoldingRanges(`unittest {
	if (x)
		y = z;
}`.normLF)[1 .. $] == [FoldingRange(18, 27)], "if not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	static if (x)
		y = z;
	else
		bar = baz;
}`.normLF)[1 .. 3] == [FoldingRange(25, 34), FoldingRange(40, 53)], "static if not folding properly");

	assert(dcdext.getFoldingRanges(`struct S {
	static if (x)
		int z;
	else
		int baz;
}`.normLF)[1 .. 3] == [FoldingRange(25, 34), FoldingRange(40, 51)], "static if (decl only) not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	version (foo)
		y = z;
	else
		bar = baz;
}`.normLF)[1 .. 3] == [FoldingRange(25, 34), FoldingRange(40, 53)], "version not folding properly");

	assert(dcdext.getFoldingRanges(`struct S {
	version (foo)
		int z;
	else
		int baz;
}`.normLF)[1 .. 3] == [FoldingRange(25, 34), FoldingRange(40, 51)], "version (decl only) not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	debug (foooo)
		y = z;
	else
		bar = baz;
}`.normLF)[1 .. 3] == [FoldingRange(25, 34), FoldingRange(40, 53)], "debug not folding properly");

	assert(dcdext.getFoldingRanges(`struct S {
	debug (foooo)
		int z;
	else
		int baz;
}`.normLF)[1 .. 3] == [FoldingRange(25, 34), FoldingRange(40, 51)], "debug (decl only) not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	foreach (x; y) {
		foo();
	}
}`.normLF)[1 .. $] == [FoldingRange(26, 40)], "foreach not folding properly");

	assert(dcdext.getFoldingRanges(`struct S {
	static foreach (x; y) {
		int x;
	}
}`.normLF)[1 .. $] == [FoldingRange(33, 47)], "static foreach (decl only) not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	static foreach (x; y) {
		foo();
	}
}`.normLF)[1 .. $] == [FoldingRange(33, 47)], "static foreach not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	for (int i = 0; i < 10; i++) {
		foo();
	}
}`.normLF)[1 .. $] == [FoldingRange(40, 54)], "for loop not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	while (x) {
		foo();
	}
}`.normLF)[1 .. $] == [FoldingRange(21, 35)], "while loop not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	do {
		foo();
	} while (x);
}`.normLF)[1 .. $] == [FoldingRange(14, 29)], "do-while not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	with (Foo) {
		bar();
	}
}`.normLF)[1 .. $] == [FoldingRange(22, 36)], "with not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	int[] x = [
		1,
		2,
		3
	];
}`.normLF)[1 .. $] == [FoldingRange(23, 39)], "array not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	int[string] x = [
		"a": 1,
		"b": 2,
		"c": 3,
	];
}`.normLF)[1 .. $] == [FoldingRange(29, 61)], "AA not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	Foo foo = {
		a: 1,
		b: 2,
		c: 3
	};
}`.normLF)[1 .. $] == [FoldingRange(23, 48)], "struct initializer not folding properly");

	// TODO: asm folding not working properly yet
	assert(dcdext.getFoldingRanges(`unittest {
	asm {
		nop;
	}
}`.normLF)[1 .. $] == [FoldingRange(15, 27)], "asm not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	asm nothrow {
		nop;
	}
}`.normLF)[1 .. $] == [FoldingRange(23, 35)], "asm with attributes not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	foo(() {
		bar();
	}, () {
		baz();
	});
}`.normLF)[1 .. $] == [FoldingRange(20, 31), FoldingRange(38, 49), FoldingRange(16, 50)], "delegate not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	tp!(() {
		bar();
	}, () {
		baz();
	});
}`.normLF)[1 .. $] == [FoldingRange(20, 31), FoldingRange(38, 49), FoldingRange(16, 50)], "delegate (template) not folding properly");

	assert(dcdext.getFoldingRanges(`struct Foo {
	int a;
}`.normLF) == [FoldingRange(10, 22)], "struct not folding properly");

	assert(dcdext.getFoldingRanges(`enum Foo {
	a,
	b,
	c
}`.normLF) == [FoldingRange(8, 23)], "enum not folding properly");

	assert(dcdext.getFoldingRanges(`unittest {
	writeln(
		"hello",
		"world"
	);
}`.normLF)[1 .. $] == [
	FoldingRange(20, 41),
], "multi-line call not folding properly");

}

private const(T) via(T)(scope const(T)[] slice, scope const(T)[] srcArray, long at)
{
	assert(srcArray.length);
	if (at >= 0 && at < slice.length)
		return slice[at];
	if (&slice[0] >= &srcArray[0] && &slice[0] < &srcArray.ptr[srcArray.length])
	{
		int i = cast(int)(&slice[0] - &srcArray[0]);
		i += cast(int)at;
		if (i < 0)
			i = 0;
		else if (i > srcArray.length)
			i = cast(int)(srcArray.length - 1);
		return srcArray[i];
	}
	assert(false, "used `via` on slice that is not part of source array!");
}
