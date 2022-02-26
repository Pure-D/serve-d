module workspaced.visitors.attributes;

import dparse.ast;
import dparse.formatter;
import dparse.lexer;

import std.algorithm;
import std.conv;
import std.range;
import std.string;
import std.variant;

class AttributesVisitor : ASTVisitor
{
	bool sticky;

	override void visit(const MemberFunctionAttribute attribute)
	{
		if (attribute.tokenType != IdType.init)
			context.attributes ~= ASTContext.AnyAttributeInfo(
					ASTContext.AnyAttribute(cast() attribute), sticky);
		attribute.accept(this);
	}

	override void visit(const FunctionAttribute attribute)
	{
		if (attribute.token.type != IdType.init)
			context.attributes ~= ASTContext.AnyAttributeInfo(ASTContext.AnyAttribute(
					ASTContext.SimpleAttribute([cast() attribute.token])), sticky);
		attribute.accept(this);
	}

	override void visit(const AtAttribute attribute)
	{
		context.attributes ~= ASTContext.AnyAttributeInfo(
				ASTContext.AnyAttribute(cast() attribute), sticky);
		attribute.accept(this);
	}

	override void visit(const PragmaExpression attribute)
	{
		context.attributes ~= ASTContext.AnyAttributeInfo(
				ASTContext.AnyAttribute(cast() attribute), sticky);
		attribute.accept(this);
	}

	override void visit(const Deprecated attribute)
	{
		context.attributes ~= ASTContext.AnyAttributeInfo(
				ASTContext.AnyAttribute(cast() attribute), sticky);
		attribute.accept(this);
	}

	override void visit(const AlignAttribute attribute)
	{
		context.attributes ~= ASTContext.AnyAttributeInfo(
				ASTContext.AnyAttribute(cast() attribute), sticky);
		attribute.accept(this);
	}

	override void visit(const LinkageAttribute attribute)
	{
		context.attributes ~= ASTContext.AnyAttributeInfo(
				ASTContext.AnyAttribute(cast() attribute), sticky);
		attribute.accept(this);
	}

	override void visit(const Attribute attribute)
	{
		Token[] tokens;
		if (attribute.attribute.type != IdType.init)
			tokens ~= attribute.attribute;
		if (attribute.identifierChain)
			tokens ~= attribute.identifierChain.identifiers;
		if (tokens.length)
			context.attributes ~= ASTContext.AnyAttributeInfo(
					ASTContext.AnyAttribute(ASTContext.SimpleAttribute(tokens)), sticky);
		attribute.accept(this);
	}

	override void visit(const StorageClass storage)
	{
		if (storage.token.type != IdType.init)
			context.attributes ~= ASTContext.AnyAttributeInfo(ASTContext.AnyAttribute(
					ASTContext.SimpleAttribute([cast() storage.token])), sticky);
		storage.accept(this);
	}

	override void visit(const AttributeDeclaration dec)
	{
		sticky = true;
		dec.accept(this);
		sticky = false;
	}

	override void visit(const Declaration dec)
	{
		auto c = context.save;
		// attribute ':' (private:)
		bool attribDecl = !!dec.attributeDeclaration;
		if (attribDecl)
		{
			sticky = true;
			processDeclaration(dec);
			sticky = false;
		}
		else
		{
			processDeclaration(dec);
			context.restore(c);
		}
	}

	override void visit(const InterfaceDeclaration dec)
	{
		auto c = context.save;
		context.pushContainer(ASTContext.ContainerAttribute.Type.class_, dec.name.text);
		super.visit(dec);
		context.restore(c);
	}

	override void visit(const ClassDeclaration dec)
	{
		auto c = context.save;
		context.pushContainer(ASTContext.ContainerAttribute.Type.class_, dec.name.text);
		super.visit(dec);
		context.restore(c);
	}

	override void visit(const StructDeclaration dec)
	{
		auto c = context.save;
		context.pushContainer(ASTContext.ContainerAttribute.Type.struct_, dec.name.text);
		super.visit(dec);
		context.restore(c);
	}

	override void visit(const UnionDeclaration dec)
	{
		auto c = context.save;
		context.pushContainer(ASTContext.ContainerAttribute.Type.union_, dec.name.text);
		super.visit(dec);
		context.restore(c);
	}

	override void visit(const EnumDeclaration dec)
	{
		auto c = context.save;
		context.pushContainer(ASTContext.ContainerAttribute.Type.enum_, dec.name.text);
		super.visit(dec);
		context.restore(c);
	}

	override void visit(const TemplateDeclaration dec)
	{
		auto c = context.save;
		context.pushContainer(ASTContext.ContainerAttribute.Type.template_, dec.name.text);
		super.visit(dec);
		context.restore(c);
	}

	void processDeclaration(const Declaration dec)
	{
		dec.accept(this);
	}

	ASTContext context;

	alias visit = ASTVisitor.visit;
}

struct ASTContext
{
	struct UserdataAttribute
	{
		string name;
		Variant variant;
	}

	struct ContainerAttribute
	{
		enum Type
		{
			class_,
			interface_,
			struct_,
			union_,
			enum_,
			template_
		}

		Type type;
		string name;
	}

	struct SimpleAttribute
	{
		Token[] attributes;

		Token attribute() @property
		{
			if (attributes.length == 1)
				return attributes[0];
			else
				return Token.init;
		}

		Token firstAttribute() @property
		{
			if (attributes.length >= 1)
				return attributes[0];
			else
				return Token.init;
		}

		string toString() const
		{
			return attributes.map!(a => a.text.length ? a.text : str(a.type)).join(".");
		}
	}

	alias AnyAttribute = Algebraic!(PragmaExpression, Deprecated, AtAttribute, AlignAttribute, LinkageAttribute,
			SimpleAttribute, MemberFunctionAttribute, ContainerAttribute, UserdataAttribute);

	class AttributeWithInfo(T)
	{
		T value;
		bool sticky;

		alias value this;

		this(T value, bool sticky)
		{
			this.value = value;
			this.sticky = sticky;
		}

		auto opUnary(string op : "*")()
		{
			return this;
		}
	}

	struct AnyAttributeInfo
	{
		AnyAttribute base;
		// if true then this attribute is applying to all the following statements in the block (attribute ':')
		bool sticky;

		AttributeWithInfo!T peek(T)()
		{
			auto ret = base.peek!T;
			if (!!ret)
				return new AttributeWithInfo!T(*ret, sticky);
			else
				return null;
		}

		alias base this;
	}

	AnyAttributeInfo[] attributes;

	/// Attributes only inside a container
	auto localAttributes() @property
	{
		auto end = attributes.retro.countUntil!(a => !!a.peek!ContainerAttribute);
		if (end == -1)
			return attributes;
		else
			return attributes[$ - end .. $];
	}

	auto attributeDescriptions() @property
	{
		return attributes.map!((a) {
			if (auto prag = a.peek!PragmaExpression)
				return "pragma(" ~ prag.identifier.text ~ ", ...["
					~ prag.argumentList.items.length.to!string ~ "])";
			else if (auto depr = a.peek!Deprecated)
				return "deprecated";
			else if (auto at = a.peek!AtAttribute)
				return "@" ~ at.identifier.text;
			else if (auto align_ = a.peek!AlignAttribute)
				return "align";
			else if (auto linkage = a.peek!LinkageAttribute)
				return "extern (" ~ linkage.identifier.text ~ (linkage.hasPlusPlus ? "++" : "") ~ ")";
			else if (auto simple = a.peek!SimpleAttribute)
				return simple.attributes.map!(a => a.text.length ? a.text : str(a.type)).join(".");
			else if (auto mfunAttr = a.peek!MemberFunctionAttribute)
				return "mfun<" ~ (mfunAttr.atAttribute
					? "@" ~ mfunAttr.atAttribute.identifier.text : "???") ~ ">";
			else if (auto container = a.peek!ContainerAttribute)
				return container.type.to!string[0 .. $ - 1] ~ " " ~ container.name;
			else if (auto user = a.peek!UserdataAttribute)
				return "user " ~ user.name;
			else
				return "Unknown type?!";
		});
	}

	private static auto formatAttributes(T)(T attributes)
	{
		return attributes.map!((a) {
			auto t = appender!string;
			if (auto prag = a.peek!PragmaExpression)
				format(t, *prag);
			else if (auto depr = a.peek!Deprecated)
				format(t, *depr);
			else if (auto at = a.peek!AtAttribute)
				format(t, *at);
			else if (auto align_ = a.peek!AlignAttribute)
				format(t, *align_);
			else if (auto linkage = a.peek!LinkageAttribute)
				format(t, *linkage);
			else if (auto simple = a.peek!SimpleAttribute)
				return simple.attributes.map!(a => a.text.length ? a.text : str(a.type)).join(".");
			else if (auto mfunAttr = a.peek!MemberFunctionAttribute)
				return str(mfunAttr.tokenType);
			else if (auto container = a.peek!ContainerAttribute)
				return null;
			else if (auto user = a.peek!UserdataAttribute)
				return null;
			else
				return "/* <<ERROR>> */";
			return t.data.strip;
		});
	}

	auto formattedAttributes() @property
	{
		return formatAttributes(attributes.normalizeAttributes);
	}

	auto localFormattedAttributes() @property
	{
		return formatAttributes(localAttributes.normalizeAttributes);
	}

	auto simpleAttributes() @property
	{
		return attributes.filter!(a => !!a.peek!SimpleAttribute)
			.map!(a => *a.peek!SimpleAttribute);
	}

	auto simpleAttributesInContainer() @property
	{
		return localAttributes.filter!(a => !!a.peek!SimpleAttribute)
			.map!(a => *a.peek!SimpleAttribute);
	}

	auto atAttributes() @property
	{
		return attributes.filter!(a => !!a.peek!AtAttribute)
			.map!(a => *a.peek!AtAttribute);
	}

	auto atAttributesInContainer() @property
	{
		return localAttributes.filter!(a => !!a.peek!AtAttribute)
			.map!(a => *a.peek!AtAttribute);
	}

	auto memberFunctionAttributes() @property
	{
		return attributes.filter!(a => !!a.peek!MemberFunctionAttribute)
			.map!(a => *a.peek!MemberFunctionAttribute);
	}

	auto memberFunctionAttributesInContainer() @property
	{
		return localAttributes.filter!(a => !!a.peek!MemberFunctionAttribute)
			.map!(a => *a.peek!MemberFunctionAttribute);
	}

	auto userdataAttributes() @property
	{
		return attributes.filter!(a => !!a.peek!UserdataAttribute)
			.map!(a => *a.peek!UserdataAttribute);
	}

	auto containerAttributes() @property
	{
		return attributes.filter!(a => !!a.peek!ContainerAttribute)
			.map!(a => *a.peek!ContainerAttribute);
	}

	bool isToken(IdType t) @property
	{
		return memberFunctionAttributes.any!(a => a.tokenType == t)
			|| simpleAttributes.any!(a => a.attribute.type == t);
	}

	bool isTokenInContainer(IdType t) @property
	{
		return memberFunctionAttributesInContainer.any!(a => a.tokenType == t)
			|| simpleAttributesInContainer.any!(a => a.attribute.type == t);
	}

	bool isNothrow() @property
	{
		return isToken(tok!"nothrow");
	}

	bool isNothrowInContainer() @property
	{
		return isTokenInContainer(tok!"nothrow");
	}

	bool isNogc() @property
	{
		return atAttributes.any!(a => a.identifier.text == "nogc");
	}

	bool isNogcInContainer() @property
	{
		return atAttributesInContainer.any!(a => a.identifier.text == "nogc");
	}

	bool isStatic() @property
	{
		return isToken(tok!"static");
	}

	bool isFinal() @property
	{
		return isToken(tok!"final");
	}

	bool isAbstract() @property
	{
		return isToken(tok!"abstract");
	}

	bool isAbstractInContainer() @property
	{
		return isTokenInContainer(tok!"abstract");
	}

	/// Returns: if a block needs implementations (virtual/abstract or interface methods)
	/// 0 = must not be implemented (not in a container, private, static or final method)
	/// 1 = optionally implementable, must be implemented if there is no function body
	/// 9 = must be implemented
	int requiredImplementationLevel() @property
	{
		auto container = containerAttributes;
		if (container.empty || protectionType == tok!"private" || isStatic || isFinal)
			return 0;
		ContainerAttribute innerContainer = container.tail(1).front;
		if (innerContainer.type == ContainerAttribute.Type.class_)
			return isAbstractInContainer ? 9 : 1;
		else // interface (or others)
			return 9;
	}

	AttributeWithInfo!SimpleAttribute protectionAttribute() @property
	{
		auto prot = simpleAttributes.filter!(a => a.firstAttribute.isProtectionToken).tail(1);
		if (prot.empty)
			return null;
		else
			return prot.front;
	}

	IdType protectionType() @property
	{
		auto attr = protectionAttribute;
		if (attr is null)
			return IdType.init;
		else
			return attr.attributes[0].type;
	}

	void pushData(string name, Variant value, bool sticky = false)
	{
		attributes ~= AnyAttributeInfo(AnyAttribute(UserdataAttribute(name, value)), sticky);
	}

	void pushData(T)(string name, T value, bool sticky = false)
	{
		pushData(name, Variant(value), sticky);
	}

	void pushContainer(ContainerAttribute.Type type, string name)
	{
		attributes ~= AnyAttributeInfo(AnyAttribute(ContainerAttribute(type, name)), false);
	}

	ASTContext save()
	{
		return ASTContext(attributes[]);
	}

	void restore(ASTContext c)
	{
		attributes = c.attributes;
	}
}

bool isProtectionToken(const Token t) @property
{
	return !!t.type.among!(tok!"public", tok!"private", tok!"protected", tok!"package");
}

ASTContext.AnyAttributeInfo[] normalizeAttributes(ASTContext.AnyAttributeInfo[] attributes)
{
	ASTContext.AnyAttributeInfo[] ret;
	ret.reserve(attributes.length);
	bool gotProtection;
	bool gotSafety;
	foreach_reverse (ref attr; attributes)
	{
		if (auto simple = attr.peek!(ASTContext.SimpleAttribute))
		{
			if (simple.firstAttribute.isProtectionToken)
			{
				if (gotProtection)
					continue;
				gotProtection = true;
			}
		}
		else if (auto at = attr.peek!AtAttribute)
		{
			// search & replace for existing @safe, @trusted, @system
			if (at.identifier.text.among!("safe", "trusted", "system"))
			{
				if (gotSafety)
					continue;
				gotSafety = true;
			}
		}
		ret ~= attr;
	}
	ret.reverse();
	return ret;
}
