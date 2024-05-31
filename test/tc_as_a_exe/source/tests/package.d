module tests;

abstract class ServedTest
{
	abstract void run();

	void tick()
	{
		pumpEvents();
		Fiber.yield();
	}

	void processResponse(void delegate(RequestMessageRaw msg) cb)
	{
		bool called;
		gotRequest = (msg) {
			called = true;
			cb(msg);
		};
		tick();
		assert(called, "no response received!");
		gotRequest = null;
	}
}

__gshared RPCProcessor rpc;
__gshared string cwd;

__gshared void delegate(RequestMessageRaw msg) gotRequest;
__gshared void delegate(RequestMessageRaw msg) gotNotify;

shared static this()
{
	gotRequest = toDelegate(&defaultRequestHandler);
	gotNotify = toDelegate(&defaultNotifyHandler);
}

void defaultRequestHandler(RequestMessageRaw msg)
{
	assert(false, "Unexpected request " ~ msg.toString);
}

void defaultNotifyHandler(RequestMessageRaw msg)
{
	info("Ignoring notification " ~ msg.toString);
}
