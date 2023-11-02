module foo.bar;

version = Foo;
debug = Bar;

void hello() {
	int x = 1;
}

int y = 2;

int
bar()
{
}

unittest
{
}

@( "named" )
unittest
{
}

private class X
{
	this(int x) {}
	this(this) {}
	~this() {}

	unittest
	{
	}
}

shared static this()
{
}

__EOF__
hello	6	f	{"signature": "()", "access": "public", "return": "void"}	46	74
y	10	v	{"access": "public", "detail": "int"}	76	86
bar	13	f	{"signature": "()", "access": "public", "return": "int"}	88	101
X	26	c	{"access": "private", "detail": "class"}	152	223
this	28	f	{"signature": "(int x)", "access": "public", "class": "X"}	163	177
~this	30	f	{"access": "public", "class": "X"}	194	204
