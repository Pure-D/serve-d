public class Foo : Bar {
	static this() {
		for (int i; i < 256; i++) {
			arr[i] = i;
		}
	}

	int[256] arr;
}
__EOF__
:verbose=true
Foo	1	c	{"access":"public", "detail":"class"}	7	111
static this()	2	C	{"access": "public", "class": "Foo"}	26	93
arr	8	v	{"access":"public", "class":"Foo", "detail":"int[256]"}	96	109
