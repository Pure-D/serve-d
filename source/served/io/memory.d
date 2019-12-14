module served.io.memory;

/// Calls `destro!false` on the value or just `destroy` if not supported.
/// Makes the value undefined/unset after calling so it shouldn't be used anymore.
void destroyUnset(T)(ref T value)
		if (__traits(compiles, destroy!false(value)) || __traits(compiles, destroy(value)))
{
	static if (__traits(compiles, destroy!false(value)))
		destroy!false(value);
	else
		destroy(value);
}

/// ditto
deprecated("Type doesn't support to be destroyed in this D version") void destroyUnset(T)(ref T value)
		if (!__traits(compiles, destroy!false(value)) && !__traits(compiles, destroy(value)))
{
}
