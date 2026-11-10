/// Visitor classifying types and groups of regions of root definitions.
module workspaced.visitors.classifier;

import workspaced.visitors.attributes;

import workspaced.helpers : determineIndentation;

import workspaced.com.dcdext;

import std.algorithm;
import std.ascii;
import std.meta;
import std.range;
import std.string;

import dparse.ast;
import dparse.lexer;

class CodeDefinitionClassifier : AttributesVisitor
{
	struct Region
	{
		CodeRegionType type;
		CodeRegionProtection protection;
		CodeRegionStatic staticness;
		string minIndentation;
		uint[2] region;
		bool affectsFollowing;

		bool sameBlockAs(in Region other)
		{
			return type == other.type && protection == other.protection && staticness == other.staticness;
		}
	}

	this(const(char)[] code)
	{
		this.code = code;
	}

	override void visit(const AliasDeclaration aliasDecl)
	{
		putRegion(CodeRegionType.aliases);
	}

	override void visit(const AliasThisDeclaration aliasDecl)
	{
		putRegion(CodeRegionType.aliases);
	}

	override void visit(const ClassDeclaration typeDecl)
	{
		putRegion(CodeRegionType.types);
	}

	override void visit(const InterfaceDeclaration typeDecl)
	{
		putRegion(CodeRegionType.types);
	}

	override void visit(const StructDeclaration typeDecl)
	{
		putRegion(CodeRegionType.types);
	}

	override void visit(const UnionDeclaration typeDecl)
	{
		putRegion(CodeRegionType.types);
	}

	override void visit(const EnumDeclaration typeDecl)
	{
		putRegion(CodeRegionType.types);
	}

	override void visit(const AnonymousEnumDeclaration typeDecl)
	{
		putRegion(CodeRegionType.types);
	}

	override void visit(const AutoDeclaration field)
	{
		putRegion(CodeRegionType.fields);
	}

	override void visit(const VariableDeclaration field)
	{
		putRegion(CodeRegionType.fields);
	}

	override void visit(const Constructor ctor)
	{
		putRegion(CodeRegionType.ctor);
	}

	override void visit(const StaticConstructor ctor)
	{
		putRegion(CodeRegionType.ctor);
	}

	override void visit(const SharedStaticConstructor ctor)
	{
		putRegion(CodeRegionType.ctor);
	}

	override void visit(const Postblit copyctor)
	{
		putRegion(CodeRegionType.copyctor);
	}

	override void visit(const Destructor dtor)
	{
		putRegion(CodeRegionType.dtor);
	}

	override void visit(const StaticDestructor dtor)
	{
		putRegion(CodeRegionType.dtor);
	}

	override void visit(const SharedStaticDestructor dtor)
	{
		putRegion(CodeRegionType.dtor);
	}

	override void visit(const FunctionDeclaration method)
	{
		putRegion((method.attributes && method.attributes.any!(a => a.atAttribute
				&& a.atAttribute.identifier.text == "property")) ? CodeRegionType.properties
				: CodeRegionType.methods);
	}

	override void visit(const Declaration dec)
	{
		writtenRegion = false;
		currentRange = [
			cast(uint) dec.tokens[0].index,
			cast(uint)(dec.tokens[$ - 1].index + dec.tokens[$ - 1].text.length + 1)
		];
		super.visit(dec);
		if (writtenRegion && regions.length >= 2 && regions[$ - 2].sameBlockAs(regions[$ - 1]))
		{
			auto range = regions[$ - 1].region;
			if (regions[$ - 1].minIndentation.scoreIndent < regions[$ - 2].minIndentation.scoreIndent)
				regions[$ - 2].minIndentation = regions[$ - 1].minIndentation;
			regions[$ - 2].region[1] = range[1];
			regions.length--;
		}
	}

	override void visit(const AttributeDeclaration dec)
	{
		auto before = context.attributes[];
		dec.accept(this);
		auto now = context.attributes;
		if (now.length > before.length)
		{
			auto permaAdded = now[before.length .. $];

		}
	}

	void putRegion(CodeRegionType type, uint[2] range = typeof(uint.init)[2].init)
	{
		if (range == typeof(uint.init)[2].init)
			range = currentRange;

		CodeRegionProtection protection;
		CodeRegionStatic staticness;

		auto prot = context.protectionAttribute;
		bool stickyProtection = false;
		if (prot)
		{
			stickyProtection = prot.sticky;
			if (prot.attributes[0].type == tok!"private")
				protection = CodeRegionProtection.private_;
			else if (prot.attributes[0].type == tok!"protected")
				protection = CodeRegionProtection.protected_;
			else if (prot.attributes[0].type == tok!"package")
			{
				if (prot.attributes.length > 1)
					protection = CodeRegionProtection.packageIdentifier;
				else
					protection = CodeRegionProtection.package_;
			}
			else if (prot.attributes[0].type == tok!"public")
				protection = CodeRegionProtection.public_;
		}

		staticness = context.isStatic ? CodeRegionStatic.static_ : CodeRegionStatic.instanced;

		if (stickyProtection)
		{
			assert(prot);
			//dfmt off
			Region pr = {
				type: cast(CodeRegionType)0,
				protection: protection,
				staticness: cast(CodeRegionStatic)0,
				region: [cast(uint) prot.attributes[0].index, cast(uint) prot.attributes[0].index],
				affectsFollowing: true
			};
			//dfmt on
			regions ~= pr;
		}

		//dfmt off
		Region r = {
			type: type,
			protection: protection,
			staticness: staticness,
			minIndentation: determineIndentation(code[range[0] .. range[1]]),
			region: range
		};
		//dfmt on
		regions ~= r;
		writtenRegion = true;
	}

	alias visit = AttributesVisitor.visit;

	bool writtenRegion;
	const(char)[] code;
	Region[] regions;
	uint[2] currentRange;
}

private int scoreIndent(string indent)
{
	auto len = indent.countUntil!(a => !a.isWhite);
	if (len == -1)
		return cast(int) indent.length;
	return indent[0 .. len].map!(a => a == ' ' ? 1 : 4).sum;
}
