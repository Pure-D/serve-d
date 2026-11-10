/// Finds methods in a specified interface or class location.
module workspaced.visitors.methodfinder;

import workspaced.visitors.attributes;

import workspaced.dparseext;

import dparse.ast;
import dparse.formatter;
import dparse.lexer;

import std.algorithm;
import std.array;
import std.range;
import std.string;

/// Information about an argument in a method defintion.
struct ArgumentInfo
{
	/// The whole definition of the argument including everything related to it as formatted code string.
	string signature;
	/// The type of the argument.
	string type;
	/// The name of the argument.
	string name;

	/// Returns just the name.
	string toString() const
	{
		return name;
	}
}

/// Information about a method definition.
struct MethodDetails
{
	/// The name of the method.
	string name;
	/// The type definition of the method without body, abstract or final.
	string signature;
	/// The return type of the method.
	string returnType;
	/// All (regular) arguments passable into this method.
	ArgumentInfo[] arguments;
	///
	bool isNothrowOrNogc;
	/// True if this function has an implementation.
	bool hasBody;
	/// True when the container is an interface or (optionally implicit) abstract class or when in class not having a body.
	bool needsImplementation;
	/// True when in a class and method doesn't have a body.
	bool optionalImplementation;
	/// Range starting at return type, going until last token before opening curly brace.
	size_t[2] definitionRange;
	/// Range containing the starting and ending braces of the body.
	size_t[2] blockRange;

	/// Signature without any attributes, constraints or parameter details other than types.
	/// Used to differentiate a method from others without computing the mangle.
	/// Returns: `"<type> <name>(<argument types>)"`
	string identifier()
	{
		return format("%s %s(%(%s,%))", returnType, name, arguments.map!"a.type");
	}
}

///
struct FieldDetails
{
	///
	string name, type;
	///
	bool isPrivate;
}

///
struct TypeDetails
{
	enum Type
	{
		none,
		class_,
		interface_,
		enum_,
		struct_,
		union_,
		alias_,
		template_,
	}

	/// Name in last element, all parents in previous elements.
	string[] name;
	///
	size_t nameLocation;
	///
	Type type;
}

///
struct ReferencedType
{
	/// Referenced type name, might be longer than actual written name because of normalization of parents.
	string name;
	/// Location of name which will start right before the last identifier of the type in a dot chain.
	size_t location;
}

/// Information about an interface or class
struct InterfaceDetails
{
	/// Entire code of the file
	const(char)[] code;
	/// True if this is a class and therefore need to override methods using $(D override).
	bool needsOverride;
	/// Name of the interface or class.
	string name;
	/// Plain old variable fields in this container.
	FieldDetails[] fields;
	/// All methods defined in this container.
	MethodDetails[] methods;
	/// A list of nested types and locations defined in this interface/class.
	TypeDetails[] types;
	// reserved for future use with templates
	string[] parents;
	/// Name of all base classes or interfaces. Should use normalizedParents,
	string[] normalizedParents;
	/// Absolute code position after the colon where the corresponding parent name starts.
	int[] parentPositions;
	/// Range containing the starting and ending braces of the body.
	size_t[2] blockRange;
	/// A (name-based) sorted set of referenced types with first occurences of every type or alias not including built-in types, but including object.d types and aliases.
	ReferencedType[] referencedTypes;

	/// Returns true if there are no non-whitespace characters inside the block.
	bool isEmpty() const
	{
		return !code.substr(blockRange).strip.length;
	}
}

class InterfaceMethodFinder : AttributesVisitor
{
	this(const(char)[] code, int targetPosition)
	{
		this.code = code;
		details.code = code;
		this.targetPosition = targetPosition;
	}

	override void visit(const StructDeclaration dec)
	{
		if (inTarget)
			return;
		else
			super.visit(dec);
	}

	override void visit(const UnionDeclaration dec)
	{
		if (inTarget)
			return;
		else
			super.visit(dec);
	}

	override void visit(const EnumDeclaration dec)
	{
		if (inTarget)
			return;
		else
			super.visit(dec);
	}

	override void visit(const ClassDeclaration dec)
	{
		if (inTarget)
			return;

		auto c = context.save();
		context.pushContainer(ASTContext.ContainerAttribute.Type.class_, dec.name.text);
		visitInterface(dec.name, dec.baseClassList, dec.structBody, true);
		context.restore(c);
	}

	override void visit(const InterfaceDeclaration dec)
	{
		if (inTarget)
			return;

		auto c = context.save();
		context.pushContainer(ASTContext.ContainerAttribute.Type.interface_, dec.name.text);
		visitInterface(dec.name, dec.baseClassList, dec.structBody, false);
		context.restore(c);
	}

	private void visitInterface(const Token name, const BaseClassList baseClassList,
			const StructBody structBody, bool needsOverride)
	{
		if (!structBody)
			return;
		if (inTarget)
			return; // ignore nested

		if (targetPosition >= name.index && targetPosition < structBody.endLocation)
		{
			details.blockRange = [structBody.startLocation, structBody.endLocation + 1];
			details.name = name.text;
			if (baseClassList)
				foreach (base; baseClassList.items)
				{
					if (!base.type2 || !base.type2.typeIdentifierPart
							|| !base.type2.typeIdentifierPart.identifierOrTemplateInstance)
						continue;
					// TODO: template support!
					details.parents ~= astToString(base.type2);
					details.normalizedParents ~= astToString(base.type2);
					details.parentPositions ~= cast(
							int) base.type2.typeIdentifierPart.identifierOrTemplateInstance.identifier.index + 1;
				}
			details.needsOverride = needsOverride;
			inTarget = true;
			structBody.accept(new NestedTypeFinder(&details, details.name));
			super.visit(structBody);
			inTarget = false;
		}
	}

	override void visit(const FunctionDeclaration dec)
	{
		if (!inTarget)
			return;

		size_t[2] definitionRange = [dec.name.index, 0];
		size_t[2] blockRange;

		if (dec.returnType !is null && dec.returnType.tokens.length > 0)
			definitionRange[0] = dec.returnType.tokens[0].index;

		if (dec.functionBody !is null && dec.functionBody.tokens.length > 0)
		{
			definitionRange[1] = dec.functionBody.tokens[0].index;
			blockRange = [
				dec.functionBody.tokens[0].index, dec.functionBody.tokens[$ - 1].index + 1
			];
		}
		else if (dec.parameters !is null && dec.parameters.tokens.length > 0)
			definitionRange[1] = dec.parameters.tokens[$ - 1].index
				+ dec.parameters.tokens[$ - 1].text.length;

		auto origBody = (cast() dec).functionBody;
		const hasBody = !!origBody && origBody.missingFunctionBody is null;
		auto origComment = (cast() dec).comment;
		const implLevel = context.requiredImplementationLevel;
		const optionalImplementation = implLevel == 1 && !hasBody;
		const needsImplementation = implLevel == 9 || optionalImplementation;
		(cast() dec).functionBody = null;
		(cast() dec).comment = null;
		scope (exit)
		{
			(cast() dec).functionBody = origBody;
			(cast() dec).comment = origComment;
		}
		auto t = appender!string;
		formatTypeTransforming(t, dec, &resolveType);
		string method = context.localFormattedAttributes.chain([t.data.strip])
			.filter!(a => a.length > 0 && !a.among!("abstract", "final")).join(" ");
		ArgumentInfo[] arguments;
		if (dec.parameters)
			foreach (arg; dec.parameters.parameters)
				arguments ~= ArgumentInfo(astToString(arg), astToString(arg.type), arg.name.text);
		string returnType = dec.returnType ? resolveType(astToString(dec.returnType)) : "void";

		// now visit to populate isNothrow, isNogc (before it would add to the localFormattedAttributes string)
		// also fills in used types
		super.visit(dec);

		details.methods ~= MethodDetails(dec.name.text, method, returnType, arguments, context.isNothrowInContainer
				|| context.isNogcInContainer, hasBody, needsImplementation,
				optionalImplementation, definitionRange, blockRange);
	}

	override void visit(const FunctionBody)
	{
	}

	override void visit(const VariableDeclaration variable)
	{
		if (!inTarget)
			return;
		if (!variable.type)
			return;
		string type = astToString(variable.type);
		auto isPrivate = context.protectionType == tok!"private";

		foreach (decl; variable.declarators)
			details.fields ~= FieldDetails(decl.name.text, type, isPrivate);

		if (variable.type)
			variable.type.accept(this); // to fill in types
	}

	override void visit(const TypeIdentifierPart type)
	{
		if (!inTarget)
			return;

		if (type.identifierOrTemplateInstance && !type.typeIdentifierPart)
		{
			auto tok = type.identifierOrTemplateInstance.templateInstance
				? type.identifierOrTemplateInstance.templateInstance.identifier
				: type.identifierOrTemplateInstance.identifier;

			usedType(ReferencedType(tok.text, tok.index));
		}

		super.visit(type);
	}

	alias visit = AttributesVisitor.visit;

	protected void usedType(ReferencedType type)
	{
		// this is a simple sorted set insert
		auto sorted = assumeSorted!"a.name < b.name"(details.referencedTypes).trisect(type);
		if (sorted[1].length)
			return; // exists already
		details.referencedTypes.insertInPlace(sorted[0].length, type);
	}

	string resolveType(const(char)[] inType)
	{
		auto parts = inType.splitter('.');
		string[] best;
		foreach (type; details.types)
			if ((!best.length || type.name.length < best.length) && type.name.endsWith(parts))
				best = type.name;

		if (best.length)
			return best.join(".");
		else
			return inType.idup;
	}

	const(char)[] code;
	bool inTarget;
	int targetPosition;
	InterfaceDetails details;
}

class NestedTypeFinder : ASTVisitor
{
	this(InterfaceDetails* details, string start)
	{
		this.details = details;
		this.nested = [start];
	}

	override void visit(const StructDeclaration dec)
	{
		handleType(TypeDetails.Type.struct_, dec.name.text, dec.name.index, dec);
	}

	override void visit(const UnionDeclaration dec)
	{
		handleType(TypeDetails.Type.union_, dec.name.text, dec.name.index, dec);
	}

	override void visit(const EnumDeclaration dec)
	{
		handleType(TypeDetails.Type.enum_, dec.name.text, dec.name.index, dec);
	}

	override void visit(const ClassDeclaration dec)
	{
		handleType(TypeDetails.Type.class_, dec.name.text, dec.name.index, dec);
	}

	override void visit(const InterfaceDeclaration dec)
	{
		handleType(TypeDetails.Type.interface_, dec.name.text, dec.name.index, dec);
	}

	override void visit(const TemplateDeclaration dec)
	{
		handleType(TypeDetails.Type.template_, dec.name.text, dec.name.index, dec);
	}

	override void visit(const AliasDeclaration dec)
	{
		if (dec && dec.declaratorIdentifierList)
			foreach (ident; dec.declaratorIdentifierList.identifiers)
				details.types ~= TypeDetails(nested ~ ident.text, ident.index, TypeDetails.Type.alias_);
	}

	void handleType(T)(TypeDetails.Type type, string name, size_t location, T node)
	{
		pushNestedType(type, name, location);
		super.visit(node);
		popNestedType();
	}

	override void visit(const FunctionBody)
	{
	}

	alias visit = ASTVisitor.visit;

	protected void pushNestedType(TypeDetails.Type type, string name, size_t index)
	{
		nested ~= name;
		details.types ~= TypeDetails(nested, index, type);
	}

	protected void popNestedType()
	{
		nested.length--;
	}

	string[] nested;
	InterfaceDetails* details;
}

void formatTypeTransforming(Sink, T)(Sink sink, T node, string delegate(const(char)[]) translateType,
		bool useTabs = false, IndentStyle style = IndentStyle.allman, uint indentWith = 4)
{
	TypeTransformingFormatter!Sink formatter = new TypeTransformingFormatter!(Sink)(sink,
			useTabs, style, indentWith);
	formatter.translateType = translateType;
	formatter.format(node);
}

///
class TypeTransformingFormatter(Sink) : Formatter!Sink
{
	string delegate(const(char)[]) translateType;
	Appender!(char[]) tempBuffer;
	bool useTempBuffer;

	this(Sink sink, bool useTabs = false, IndentStyle style = IndentStyle.allman, uint indentWidth = 4)
	{
		super(sink, useTabs, style, indentWidth);
		tempBuffer = appender!(char[]);
	}

	override void put(string s)
	{
		if (useTempBuffer)
			tempBuffer.put(s);
		else
			super.put(s);
	}

	protected void flushTempBuffer()
	{
		if (!useTempBuffer || tempBuffer.data.empty)
			return;

		useTempBuffer = false;
		put(translateType(tempBuffer.data));
		tempBuffer.clear();
	}

	override void format(const TypeIdentifierPart type)
	{
		useTempBuffer = true;

		if (type.dot)
		{
			put(".");
		}
		if (type.identifierOrTemplateInstance)
		{
			format(type.identifierOrTemplateInstance);
		}
		if (type.indexer)
		{
			flushTempBuffer();
			put("[");
			format(type.indexer);
			put("]");
		}
		if (type.typeIdentifierPart)
		{
			put(".");
			format(type.typeIdentifierPart);
		}
		else
		{
			flushTempBuffer();
		}
	}

	override void format(const IdentifierOrTemplateInstance identifierOrTemplateInstance)
	{
		with (identifierOrTemplateInstance)
		{
			format(identifier);
			if (templateInstance)
			{
				flushTempBuffer();
				format(templateInstance);
			}
		}
	}

	alias format = Formatter!Sink.format;
}
