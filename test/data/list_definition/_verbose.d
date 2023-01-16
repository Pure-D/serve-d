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
:verbose=true
Foo	3	V	{"access": "public"}	17	31
Bar	4	D	{"access": "public"}	32	44
hello	6	f	{"signature": "()", "access": "public", "return": "void"}	46	74
y	10	v	{"access": "public"}	76	86
bar	13	f	{"signature": "()", "access": "public", "return": "int"}	88	101
__unittest_L17_C1	17	U	{"access": "public"}	103	115
__unittest_L22_C1	22	U	{"access": "public", "name": "named"}	130	142
X	26	c	{"access": "public"}	144	215
this	28	f	{"signature": "(int x)", "access": "public", "class": "X"}	155	169
this(this)	29	f	{"access": "public", "class": "X"}	171	184
~this	30	f	{"access": "public", "class": "X"}	186	196
__unittest_L32_C2	32	U	{"access": "public", "class": "X"}	199	213
shared static this()	37	S	{"access": "public"}	217	241
