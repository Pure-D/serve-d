module properties;

class Foo : Bar
{
	private int m_tree;
	private int mCar;
	private int _heli;
	private int sharp;
	private int java;
}

interface Bar
{
	int tree() @property;
	void tree(int value) @property;
	int car() @property;
	void car(int foobar) @property;
	int heli() @property;
	void heli(int value) @property;
	int Sharp() @property;
	void Sharp(int value) @property;
	int getJava();
	void setJava(int value);

	int getter() @property;
	void setter(int value) @property;
}