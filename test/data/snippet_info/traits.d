void foo()
{
	static if (__traits(foo))
	{
	}
}

void bar()
{
	static if (__traits())
	{
	}
}

__EOF__
34	other
36	other
37	other
83	other
