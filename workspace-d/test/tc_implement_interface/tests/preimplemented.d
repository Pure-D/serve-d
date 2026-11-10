module preimplemented;

class Element : Node, Node2
{
	void wronglyImplemented()
	{
	}

	string name() @property
	{
		return "foo";
	}
}

interface Node
{
	void addChild(Node n);
	bool wronglyImplemented();
	string name() @property;
}

interface Node2
{
	void removeChild(Node n);
}
