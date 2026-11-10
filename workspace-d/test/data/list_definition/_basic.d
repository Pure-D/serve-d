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

class X
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
hello	6	f	{"signature": "()", "access": "public", "return": "void"}	59	73
y	10	v	{"access": "public"}	80	81
bar	13	f	{"signature": "()", "access": "public", "return": "int"}	98	100
X	26	c	{"access": "public"}	152	214
this	28	f	{"signature": "(int x)", "access": "public", "class": "X"}	167	168
~this	30	f	{"access": "public", "class": "X"}	194	195
