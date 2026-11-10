module nested_types;

class CoolClassImpl : CoolClass
{

}

abstract class CoolClass
{
	struct Helper
	{
		int x, y;

		void foo()
		{
		}
	}

	class Helper2
	{
		string foo;

		void bar();
	}

	void toImplement();
	Helper accessHelper();
	Helper2 accessHelper2();
}
