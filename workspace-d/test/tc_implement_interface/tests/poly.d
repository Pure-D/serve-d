module poly;

class Foo : IFoo1, IFoo2
{
}

interface IFoo1 : IFoo
{
	void firstFoo();
}

interface IFoo2 : IFoo
{
	void secondFoo();
}

interface IFoo
{
	void baseFoo();
}
