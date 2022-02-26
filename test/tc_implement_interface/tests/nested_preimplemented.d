module nested_preimplemented;

class HTMLElement : Element
{
	string name() @property
	{
		return "foo";
	}
}

abstract class Element : Node
{
	string tagName() @property
	{
		return "x";
	}

	abstract int numAttributes() @property;

	abstract string getAttribute(string name)
	{
		return name;
	}

	final void dontImplement() {}
}

interface Node
{
	void addChild(Node n);
	string name() @property;
	string tagName() @property;
}
