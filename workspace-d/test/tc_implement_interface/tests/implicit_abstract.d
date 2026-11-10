module implicit_abstract;

class Foo : Bar
{
}

class Bar
{
	abstract int prop() @property;
}
