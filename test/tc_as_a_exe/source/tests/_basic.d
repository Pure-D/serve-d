module tests._basic;

import tests;

class BasicTests : ServedInstancedTest
{
	this(string servedExe)
	{
		super(servedExe, buildPath(__FILE_FULL_PATH__, "../.."));
	}

	override void runImpl()
	{
		// dfmt off
		WorkspaceClientCapabilities workspace = {
			configuration: opt(true)
		};
		InitializeParams init = InitializeParams(
			processId: typeof(InitializeParams.processId)(thisProcessID),
			rootUri: uriFromFile(cwd),
			capabilities: ClientCapabilities(
				workspace: opt(workspace)
			)
		);
		// dfmt on
		auto msg = rpc.sendRequest("initialize", init, 10.seconds);
		info("Response: ", msg.resultJson);

		info("Shutting down...");
		rpc.sendRequest("shutdown", init);
		pumpEvents();
		Fiber.yield();
		rpc.notifyMethod("exit");
		pumpEvents();
		Thread.sleep(2.seconds); // give serve-d a chance to clean up
		Fiber.yield();
	}
}
